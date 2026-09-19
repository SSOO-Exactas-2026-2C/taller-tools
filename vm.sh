#!/usr/bin/env bash
#
# Gestión de la VM de qemu para los talleres de Sistemas Operativos.
#
# Este script es GENÉRICO: no sabe nada de los ejercicios de un taller en
# particular. Vive en el repo taller-tools, compartido por todos los talleres
# de la materia, y cada taller lo clona en su carpeta tools/ la primera vez
# que corre make. Lo específico de cada taller vive en su Makefile.
#
# Idea general
# ------------
# Todo se compila y ejecuta adentro de una VM Debian, no en la máquina del
# alumno. Así el entorno es idéntico en Linux, macOS (Intel y Apple Silicon)
# y Windows (vía WSL2), y herramientas como strace funcionan siempre.
#
# La carpeta del taller (donde está el Makefile) se comparte con la VM por
# 9p y se monta en /taller adentro del guest. El Makefile ejecuta gcc, los
# binarios y los tests por ssh, con rutas relativas a esa carpeta.
#
# Hay dos niveles de imagen:
#
#   1. Una imagen BASE, que se descarga y provisiona UNA sola vez por
#      máquina, y queda cacheada en ~/.local/share/taller-so (compartida
#      entre todos los talleres).
#   2. Un OVERLAY por taller (vm/taller.qcow2), que ocupa unos pocos MB y
#      guarda los cambios de ese taller. Se puede borrar y recrear sin
#      volver a descargar nada.
#
# Subcomandos:
#   install   descarga + provisiona la imagen base (idempotente)
#   start     levanta la VM de este taller (no hace nada si ya corre)
#   stop      la apaga
#   status    informa si corre, en qué puerto y con qué acelerador
#   exec      corre un comando adentro de la VM, parado en /taller
#   run       igual que exec, pero pide tty si estamos en una terminal
#             (así Ctrl-C llega al proceso remoto y a sus hijos)
#   shell     abre una sesión interactiva
#   destroy   apaga la VM y borra el overlay de este taller
#   purge     además borra la imagen base cacheada
#
set -u

# ---------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------

# Dónde vive este script y lo que lo acompaña (la plantilla de cloud-init).
TOOLS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Directorio del taller (donde está el Makefile): se comparte con la VM. Es
# otra cosa que TOOLS_DIR, porque este repo se clona ADENTRO del taller: el
# Makefile lo pasa por entorno. El default de acá sirve para poder correr
# vm.sh a mano desde tools/, sin make.
WORKSHOP_DIR="${WORKSHOP_DIR:-$(cd "$TOOLS_DIR/.." && pwd)}"

# Estado propio de este taller.
VM_DIR="$WORKSHOP_DIR/vm"
OVERLAY="$VM_DIR/taller.qcow2"
PIDFILE="$VM_DIR/vm.pid"
PORTFILE="$VM_DIR/vm.port"
CONSOLE_LOG="$VM_DIR/console.log"

# Cache compartido entre talleres.
CACHE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/taller-so"
BASE_IMG="$CACHE_DIR/debian-12-generic-amd64.qcow2"
BASE_VERIFIED="$CACHE_DIR/base.verified"   # descargada y con checksum OK
BASE_READY="$CACHE_DIR/base.ready"         # además ya provisionada
SSH_KEY="$CACHE_DIR/id_taller"

IMG_URL_DIR="https://cloud.debian.org/images/cloud/bookworm/latest"
IMG_NAME="debian-12-generic-amd64.qcow2"

GUEST_USER="tallerso"
GUEST_PASS="tallerso"
GUEST_DIR="/taller"         # donde se ve la carpeta del taller adentro de la VM
MOUNT_TAG="shared"

VM_RAM="${VM_RAM:-512}"
VM_CPUS="${VM_CPUS:-2}"
DISK_EXTRA="${DISK_EXTRA:-8G}"   # cuánto se agranda la imagen base
SSH_PORT_BASE="${SSH_PORT:-2222}"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"   # segundos que esperamos al ssh

# ---------------------------------------------------------------------
# Salida
# ---------------------------------------------------------------------

if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

info()  { echo "${C_OK}==>${C_OFF} $*"; }
warn()  { echo "${C_WARN}==> $*${C_OFF}" >&2; }
error() { echo "${C_ERR}error:${C_OFF} $*" >&2; }
die()   { error "$*"; exit 1; }

# Pregunta sí/no. Si no hay terminal (CI), responde que no.
confirm() {
    local question="$1" answer
    if [ ! -t 0 ]; then
        return 1
    fi
    printf '%s [s/N] ' "$question" >&2
    read -r answer
    case "$answer" in
        [sS]|[sS][iI]|[yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------
# Detección de plataforma
# ---------------------------------------------------------------------

HOST_OS=$(uname -s)
HOST_ARCH=$(uname -m)

is_wsl() {
    [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null
}

# La VM es SIEMPRE x86_64, en todas las plataformas: el binario de
# referencia de la cátedra viene precompilado para esa arquitectura y
# queremos que la traza de strace sea idéntica para todos los alumnos.
#
# Consecuencia: en una Mac con Apple Silicon no hay aceleración por
# hardware (HVF solo acelera guests de la misma arquitectura que el host),
# así que la VM corre emulada por software. Anda igual, pero más lento.
accelerator() {
    case "$HOST_OS" in
        Darwin)
            if [ "$HOST_ARCH" = "x86_64" ]; then
                echo "hvf"
            else
                echo "tcg"
            fi
            ;;
        Linux)
            if [ "$HOST_ARCH" = "x86_64" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
                echo "kvm"
            else
                echo "tcg"
            fi
            ;;
        *)
            echo "tcg"
            ;;
    esac
}

accelerator_flags() {
    case "$(accelerator)" in
        hvf) echo "-accel hvf -cpu host" ;;
        kvm) echo "-accel kvm -cpu host" ;;
        *)   echo "-accel tcg -cpu max" ;;
    esac
}

# ---------------------------------------------------------------------
# Dependencias del host
# ---------------------------------------------------------------------

# Con qué herramienta armamos el ISO de configuración (cloud-init).
iso_tool() {
    if [ "$HOST_OS" = "Darwin" ] && command -v hdiutil >/dev/null 2>&1; then
        echo hdiutil
    elif command -v xorriso >/dev/null 2>&1; then
        echo xorriso
    elif command -v genisoimage >/dev/null 2>&1; then
        echo genisoimage
    elif command -v mkisofs >/dev/null 2>&1; then
        echo mkisofs
    fi
}

missing_dependencies() {
    local missing=""
    command -v qemu-system-x86_64 >/dev/null 2>&1 || missing="$missing qemu"
    command -v qemu-img          >/dev/null 2>&1 || missing="$missing qemu-img"
    command -v ssh               >/dev/null 2>&1 || missing="$missing ssh"
    command -v ssh-keygen        >/dev/null 2>&1 || missing="$missing ssh-keygen"
    command -v curl              >/dev/null 2>&1 || missing="$missing curl"
    [ -n "$(iso_tool)" ]                          || missing="$missing iso"
    echo "$missing"
}

install_dependencies() {
    local missing
    missing=$(missing_dependencies)
    if [ -z "$missing" ]; then
        info "Dependencias del host: OK ($(accelerator))"
        return 0
    fi

    warn "Faltan dependencias en tu máquina:$missing"

    local cmd=""
    case "$HOST_OS" in
        Darwin)
            if ! command -v brew >/dev/null 2>&1; then
                cat >&2 <<'EOF'

No encontré Homebrew, que es la forma más simple de instalar qemu en macOS.

Instalalo con (copiar y pegar, lo pide la página oficial https://brew.sh):

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

y después volvé a correr "make install". Si preferís no usar Homebrew,
instalá qemu a mano y asegurate de que "qemu-system-x86_64" y "qemu-img"
estén en el PATH.
EOF
                exit 1
            fi
            cmd="brew install qemu"
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                cmd="sudo apt-get update && sudo apt-get install -y qemu-system-x86 qemu-utils xorriso openssh-client curl"
            elif command -v dnf >/dev/null 2>&1; then
                cmd="sudo dnf install -y qemu-system-x86 qemu-img xorriso openssh-clients curl"
            elif command -v pacman >/dev/null 2>&1; then
                cmd="sudo pacman -S --needed qemu-img qemu-system-x86 xorriso openssh curl"
            else
                cat >&2 <<'EOF'

No reconocí el gestor de paquetes de tu distribución. Instalá a mano:

  qemu-system-x86 (o qemu-kvm), qemu-img, xorriso (o genisoimage),
  el cliente de ssh y curl.

Y después volvé a correr "make install".
EOF
                exit 1
            fi
            ;;
        *)
            die "Sistema operativo no soportado: $HOST_OS. En Windows instala WSL2 y corre el taller adentro (ver VM.md)."
            ;;
    esac

    echo "" >&2
    echo "Se puede resolver con:" >&2
    echo "" >&2
    echo "  $cmd" >&2
    echo "" >&2
    if ! confirm "Querés que lo ejecute ahora?"; then
        die "Instalá las dependencias y volvé a correr \"make install\"."
    fi

    eval "$cmd" || die "Falló la instalación de dependencias."

    missing=$(missing_dependencies)
    [ -z "$missing" ] || die "Todavía faltan dependencias:$missing"
    info "Dependencias del host: OK"
}

warn_about_kvm() {
    [ "$HOST_OS" = "Linux" ] || return 0
    [ -e /dev/kvm ] || return 0
    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        warn "Existe /dev/kvm pero no tenés permiso para usarlo: la VM va a ir MUCHO más lenta."
        warn "Se arregla con:  sudo usermod -aG kvm \$USER   (y volver a iniciar sesión)"
    fi
}

# ---------------------------------------------------------------------
# ssh
# ---------------------------------------------------------------------

# Ojo con stdin: un ssh sin "-n" lee su entrada estándar y se la manda al
# comando remoto. Si el taller se invoca con la entrada redirigida
# (echo "ls" | make run-minishell), cualquier ssh auxiliar que corra antes
# —la sonda de ssh_ready, el gcc del build— se come esa entrada y el
# programa del alumno arranca directamente en EOF. Por eso TODOS los ssh
# internos llevan "-n"; los únicos que reenvían stdin son los que corren el
# programa del alumno (cmd_run) y la shell interactiva.
#
# Usamos una clave generada automáticamente, guardada en el cache. No es
# por seguridad (la VM solo escucha en localhost): es para que "make"
# pueda entrar sin frenarse a pedir una contraseña. El usuario tallerso
# igual tiene la clave "tallerso" por si querés entrar a mano.
ssh_opts() {
    echo "-i $SSH_KEY \
-o IdentitiesOnly=yes \
-o StrictHostKeyChecking=no \
-o UserKnownHostsFile=/dev/null \
-o GlobalKnownHostsFile=/dev/null \
-o LogLevel=ERROR \
-o ConnectTimeout=5 \
-o SetEnv=LC_ALL=C \
-p $(current_port)"
}

current_port() {
    if [ -f "$PORTFILE" ]; then
        cat "$PORTFILE"
    else
        echo "$SSH_PORT_BASE"
    fi
}

# Cada taller usa su propio puerto, así se pueden tener dos VMs prendidas
# al mismo tiempo sin pisarse.
free_port() {
    local p="$SSH_PORT_BASE"
    while [ "$p" -lt 2400 ]; do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
            echo "$p"
            return 0
        fi
        p=$((p + 1))
    done
    die "No encontré un puerto libre entre $SSH_PORT_BASE y 2400."
}

ssh_ready() {
    # shellcheck disable=SC2046
    ssh -n $(ssh_opts) -o BatchMode=yes "$GUEST_USER@127.0.0.1" true 2>/dev/null
}

wait_for_ssh() {
    local deadline=$((SECONDS + BOOT_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ssh_ready; then
            return 0
        fi
        if [ -f "$PIDFILE" ] && ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            error "El proceso de qemu murió. Últimas líneas de $CONSOLE_LOG:"
            tail -20 "$CONSOLE_LOG" >&2 2>/dev/null || true
            return 1
        fi
        sleep 2
    done
    error "La VM no respondió por ssh después de ${BOOT_TIMEOUT}s."
    error "Mirá la consola de la VM en: $CONSOLE_LOG"
    return 1
}

# ---------------------------------------------------------------------
# install: imagen base
# ---------------------------------------------------------------------

download_base() {
    mkdir -p "$CACHE_DIR"

    # La marca es necesaria porque después de descargarla la imagen se
    # modifica (se agranda y se provisiona): a partir de ahí su checksum
    # ya no puede coincidir con el del sitio de Debian.
    if [ -f "$BASE_VERIFIED" ]; then
        return 0
    fi

    if [ ! -f "$BASE_IMG" ]; then
        info "Descargando la imagen de Debian 12 (~400 MB, una sola vez para todos los talleres)..."
        curl -fL -C - --progress-bar -o "$BASE_IMG" "$IMG_URL_DIR/$IMG_NAME" \
            || die "No pude descargar la imagen desde $IMG_URL_DIR/$IMG_NAME"
    fi

    info "Verificando el checksum de la imagen..."
    local sums expected actual
    sums="$CACHE_DIR/SHA512SUMS"
    curl -fsL -o "$sums" "$IMG_URL_DIR/SHA512SUMS" \
        || die "No pude descargar $IMG_URL_DIR/SHA512SUMS"
    expected=$(awk -v n="$IMG_NAME" '$2 == n {print $1}' "$sums")
    [ -n "$expected" ] || die "No encontré el checksum de $IMG_NAME en SHA512SUMS."

    if command -v sha512sum >/dev/null 2>&1; then
        actual=$(sha512sum "$BASE_IMG" | awk '{print $1}')
    else
        actual=$(shasum -a 512 "$BASE_IMG" | awk '{print $1}')
    fi

    if [ "$expected" != "$actual" ]; then
        rm -f "$BASE_IMG"
        die "El checksum de la imagen no coincide (descarga corrupta). Volvé a correr \"make install\"."
    fi
    touch "$BASE_VERIFIED"
    info "Checksum OK"
}

generate_key() {
    [ -f "$SSH_KEY" ] && return 0
    info "Generando la clave de acceso a la VM..."
    ssh-keygen -q -t ed25519 -N '' -C "taller-so" -f "$SSH_KEY" \
        || die "No pude generar la clave ssh."
    chmod 600 "$SSH_KEY"
}

build_seed() {
    # Arma el ISO con la configuración de cloud-init (usuario, clave,
    # carpeta compartida, paquetes). Solo se usa la primera vez, para
    # provisionar la imagen base.
    local dir="$1" iso="$2" pubkey
    local template="$TOOLS_DIR/cloud-init/user-data.tpl"
    local metadata="$TOOLS_DIR/cloud-init/meta-data"

    # Si algo de esto falla el ISO igual se arma, pero sale vacío o con los
    # @PLACEHOLDERS@ sin reemplazar, y el error recién aparece mucho después
    # como una VM que no bootea o a la que no se le puede entrar por ssh.
    # Mejor cortar acá, donde se entiende qué pasó.
    pubkey=$(cat "$SSH_KEY.pub") \
        || die "No pude leer la clave pública $SSH_KEY.pub."
    [ -f "$template" ] || die "Falta $template."
    [ -f "$metadata" ] || die "Falta $metadata."

    mkdir -p "$dir" || die "No pude crear la carpeta de trabajo $dir."
    sed -e "s|@SSH_PUBKEY@|$pubkey|" \
        -e "s|@HOST_UID@|$(id -u)|" \
        -e "s|@GUEST_USER@|$GUEST_USER|g" \
        -e "s|@GUEST_PASS@|$GUEST_PASS|" \
        -e "s|@GUEST_DIR@|$GUEST_DIR|g" \
        -e "s|@MOUNT_TAG@|$MOUNT_TAG|" \
        "$template" > "$dir/user-data" \
        || die "No pude generar $dir/user-data a partir de $template."
    cp "$metadata" "$dir/meta-data" \
        || die "No pude copiar $metadata a $dir/meta-data."

    rm -f "$iso"
    # La etiqueta del volumen TIENE que ser CIDATA: así la encuentra
    # cloud-init (datasource NoCloud).
    case "$(iso_tool)" in
        hdiutil)
            hdiutil makehybrid -quiet -iso -joliet \
                -default-volume-name CIDATA -o "$iso" "$dir" >/dev/null \
                || die "No pude armar el ISO de configuración con hdiutil."
            ;;
        xorriso)
            xorriso -as mkisofs -quiet -V CIDATA -J -r -o "$iso" "$dir" \
                || die "No pude armar el ISO de configuración con xorriso."
            ;;
        genisoimage|mkisofs)
            "$(iso_tool)" -quiet -V CIDATA -J -r -o "$iso" "$dir" \
                || die "No pude armar el ISO de configuración."
            ;;
        *)
            die "No encontré ninguna herramienta para armar el ISO (xorriso/genisoimage/hdiutil)."
            ;;
    esac
}

provision_base() {
    [ -f "$BASE_READY" ] && return 0

    local seed_dir="$CACHE_DIR/seed"
    local seed_iso="$CACHE_DIR/seed.iso"

    generate_key
    build_seed "$seed_dir" "$seed_iso"

    # Con marca, para no agrandarla de nuevo si hay que reintentar la
    # provisión.
    if [ ! -f "$CACHE_DIR/base.resized" ]; then
        info "Agrandando el disco de la imagen (+$DISK_EXTRA)..."
        qemu-img resize -q "$BASE_IMG" "+$DISK_EXTRA" >/dev/null \
            || die "No pude agrandar la imagen base."
        touch "$CACHE_DIR/base.resized"
    fi

    info "Preparando la VM por primera vez (instala las herramientas del taller; puede tardar unos minutos)..."
    local pidfile="$CACHE_DIR/base.pid"
    local console_log="$CACHE_DIR/base-console.log"
    local port
    port=$(free_port)
    rm -f "$pidfile" "$console_log"

    # shellcheck disable=SC2046
    qemu-system-x86_64 \
        -m 1024 -smp "$VM_CPUS" $(accelerator_flags) \
        -drive "file=$BASE_IMG,if=virtio,format=qcow2" \
        -drive "file=$seed_iso,if=virtio,format=raw,media=cdrom" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" \
        -device virtio-net-pci,netdev=net0 \
        -display none -daemonize -pidfile "$pidfile" \
        -serial "file:$console_log" \
        || die "No pude arrancar la VM para prepararla."

    # Durante la provisión usamos el puerto elegido acá.
    mkdir -p "$VM_DIR"
    echo "$port" > "$PORTFILE"

    local deadline=$((SECONDS + BOOT_TIMEOUT))
    local ok=1
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ssh_ready; then ok=0; break; fi
        if ! kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
            error "El proceso de qemu murió durante la preparación. Consola en: $console_log"
            break
        fi
        sleep 3
    done

    if [ "$ok" -ne 0 ]; then
        kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || true
        rm -f "$PORTFILE"
        error "La VM no respondió por ssh durante la preparación."
        error "Mirá la consola en: $console_log"
        exit 1
    fi

    info "Esperando a que termine la configuración inicial..."
    # shellcheck disable=SC2046
    ssh -n $(ssh_opts) "$GUEST_USER@127.0.0.1" \
        'sudo cloud-init status --wait >/dev/null 2>&1; sudo cloud-init status' \
        || warn "cloud-init no terminó limpio; sigo y verifico las herramientas."

    info "Verificando las herramientas adentro de la VM..."
    local tool missing_tools=""
    for tool in gcc strace nm make setsid timeout pkill python3 lsof nc; do
        # shellcheck disable=SC2046
        ssh -n $(ssh_opts) "$GUEST_USER@127.0.0.1" "command -v $tool >/dev/null" \
            || missing_tools="$missing_tools $tool"
    done
    # shellcheck disable=SC2046
    ssh -n $(ssh_opts) "$GUEST_USER@127.0.0.1" \
        'ls /lib/modules/$(uname -r)/kernel/fs/9p >/dev/null 2>&1' \
        || missing_tools="$missing_tools módulo-9p"

    if [ -n "$missing_tools" ]; then
        kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || true
        rm -f "$PORTFILE"
        error "La VM quedó incompleta, falta:$missing_tools"
        die "Consola de la VM en: $console_log"
    fi

    info "Apagando la VM de preparación..."
    # shellcheck disable=SC2046
    ssh -n $(ssh_opts) "$GUEST_USER@127.0.0.1" 'sudo poweroff' >/dev/null 2>&1 || true

    local shutdown_deadline=$((SECONDS + 60))
    while [ "$SECONDS" -lt "$shutdown_deadline" ]; do
        kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || true
    rm -f "$pidfile" "$PORTFILE"
    rm -rf "$seed_dir"

    touch "$BASE_READY"
    info "Imagen base lista (queda cacheada en $CACHE_DIR)"
}

cmd_install() {
    install_dependencies
    warn_about_kvm
    download_base
    provision_base
    echo ""
    info "Listo. Ahora podés usar:"
    echo "    make start-vm     levanta la VM"
    echo "    make test         corre todas las pruebas adentro de la VM"
    echo "    make help         todo lo que podés hacer en este taller"
}

# ---------------------------------------------------------------------
# start / stop / status
# ---------------------------------------------------------------------

running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

# Candado para que dos "make" simultáneos no arranquen dos VMs sobre el
# mismo disco (lo corromperían). El que llega segundo espera al primero.
take_lock() {
    local lock="$VM_DIR/.lock" attempts=0
    mkdir -p "$VM_DIR"
    while ! mkdir "$lock" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -gt "$BOOT_TIMEOUT" ]; then
            die "Otro proceso quedó trabado arrancando la VM. Borrá $lock y probá de nuevo."
        fi
        sleep 1
    done
    trap 'rmdir "$VM_DIR/.lock" 2>/dev/null || true' EXIT
}

release_lock() {
    rmdir "$VM_DIR/.lock" 2>/dev/null || true
    trap - EXIT
}

cmd_start() {
    if running && ssh_ready; then
        return 0
    fi

    if [ ! -f "$BASE_READY" ]; then
        die "La VM no está instalada todavía. Corré primero:  make install"
    fi

    take_lock

    # Puede haber arrancado mientras esperábamos el candado.
    if running && ssh_ready; then
        release_lock
        return 0
    fi

    # Si el proceso de qemu está vivo pero todavía no responde, es que
    # está booteando: hay que esperarlo, no arrancar una segunda VM.
    if running; then
        info "La VM está arrancando, espero..."
        wait_for_ssh || { release_lock; exit 1; }
        release_lock
        return 0
    fi

    # Si quedó un pidfile viejo de un proceso muerto, lo limpiamos.
    rm -f "$PIDFILE"

    if [ ! -f "$OVERLAY" ]; then
        info "Creando el disco de este taller..."
        qemu-img create -q -f qcow2 -b "$BASE_IMG" -F qcow2 "$OVERLAY" >/dev/null \
            || die "No pude crear el disco de la VM."
    fi

    local port
    port=$(free_port)
    echo "$port" > "$PORTFILE"

    info "Levantando la VM (puerto ssh $port, acelerador $(accelerator))..."
    rm -f "$CONSOLE_LOG"

    # La carpeta del taller se comparte por 9p con el tag "shared".
    # security_model=none hace que los archivos conserven el uid del host,
    # así se pueden editar de los dos lados sin problemas de permisos.
    # shellcheck disable=SC2046
    qemu-system-x86_64 \
        -m "$VM_RAM" -smp "$VM_CPUS" $(accelerator_flags) \
        -drive "file=$OVERLAY,if=virtio,format=qcow2" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" \
        -device virtio-net-pci,netdev=net0 \
        -virtfs "local,path=$WORKSHOP_DIR,mount_tag=$MOUNT_TAG,security_model=none,id=shared" \
        -display none -daemonize -pidfile "$PIDFILE" \
        -serial "file:$CONSOLE_LOG" \
        || die "No pude arrancar la VM."

    wait_for_ssh || exit 1

    # La carpeta compartida se monta sola (fstab), pero si el montaje falló
    # lo reintentamos a mano y, si tampoco anda, avisamos con un mensaje
    # entendible en vez de dejar que el build tire "no such file or directory".
    #
    # El centinela es el Makefile: es lo que define a la carpeta de un taller
    # y está siempre versionado (tools/ no sirve, es un clon ignorado por git).
    # shellcheck disable=SC2046
    ssh -n $(ssh_opts) "$GUEST_USER@127.0.0.1" "test -f $GUEST_DIR/Makefile" 2>/dev/null || {
        # shellcheck disable=SC2046
        ssh -n $(ssh_opts) "$GUEST_USER@127.0.0.1" \
            "sudo mkdir -p $GUEST_DIR && sudo mount -t 9p -o trans=virtio,version=9p2000.L,rw,msize=512000 $MOUNT_TAG $GUEST_DIR" 2>/dev/null || true
        # shellcheck disable=SC2046
        ssh -n $(ssh_opts) "$GUEST_USER@127.0.0.1" "test -f $GUEST_DIR/Makefile" 2>/dev/null \
            || die "La carpeta compartida no se montó adentro de la VM. Probá 'make clean-vm' y de nuevo 'make start-vm'."
    }

    info "VM lista"
    # Se suelta apenas la VM está arriba: el candado solo protege el
    # arranque, no el comando que venga después.
    release_lock
}

cmd_stop() {
    if ! running; then
        rm -f "$PIDFILE" "$PORTFILE"
        info "La VM no estaba corriendo"
        return 0
    fi

    local pid
    pid=$(cat "$PIDFILE")

    info "Apagando la VM..."
    # shellcheck disable=SC2046
    ssh -n $(ssh_opts) -o BatchMode=yes "$GUEST_USER@127.0.0.1" 'sudo poweroff' >/dev/null 2>&1 || true

    local deadline=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$deadline" ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
        warn "No se apago sola; la mató."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$PIDFILE" "$PORTFILE"
    info "VM apagada"
}

cmd_status() {
    if running; then
        echo "VM:         corriendo (pid $(cat "$PIDFILE"))"
        echo "ssh:        $GUEST_USER@127.0.0.1 -p $(current_port)  (clave: $GUEST_PASS)"
        echo "acelerador: $(accelerator)"
        echo "compartida: $WORKSHOP_DIR  ->  $GUEST_DIR"
        echo "consola:    $CONSOLE_LOG"
    else
        echo "VM:         apagada"
        if [ -f "$BASE_READY" ]; then
            echo "imagen:     lista en $CACHE_DIR"
        else
            echo "imagen:     sin instalar (corre 'make install')"
        fi
    fi
}

# ---------------------------------------------------------------------
# exec / run / shell
# ---------------------------------------------------------------------

# Todos los comandos se ejecutan parados en la carpeta compartida, así el
# Makefile y los tests usan siempre rutas relativas.
#
# Ojo con el "cd": va como un comando aparte, terminado en ";", y no como
# "cd $GUEST_DIR && $*". Con el && , un comando que arranque con algo en
# segundo plano ("./servidor & sleep 1; ...") se parsea como
# "(cd && ./servidor) &", el cd se lo come el subshell, y todo lo que
# viene después corre desde el home en vez de desde el taller.
_remote() {
    local flags="$1"; shift
    cmd_start
    # shellcheck disable=SC2046
    ssh $flags $(ssh_opts) "$GUEST_USER@127.0.0.1" "cd $GUEST_DIR || exit 1; $*"
}

# Para compilar: sin tty. Así stdout y stderr llegan separados y sin
# traducir los saltos de línea, y el exit code viaja tal cual. Y con "-n",
# porque gcc no lee stdin y si no se comería lo que el usuario le esté
# mandando por un pipe al programa que corre después.
cmd_exec() { _remote "-n" "$@"; }

# Para correr los programas del taller: si estamos en una terminal
# pedimos tty, para que se comporte como si el programa corriera en tu
# máquina (Ctrl-C llega al proceso y a sus hijos, y no quedan procesos
# colgados adentro de la VM). Si la salida está redirigida a un archivo
# o a otro comando, no pedimos tty y las dos salidas quedan separadas.
cmd_run() {
    if [ -t 0 ] && [ -t 1 ]; then
        _remote "-t" "$@"
    else
        _remote "" "$@"
    fi
}

cmd_shell() {
    cmd_start
    # shellcheck disable=SC2046
    ssh -t $(ssh_opts) "$GUEST_USER@127.0.0.1"
}

# ---------------------------------------------------------------------
# destroy / purge
# ---------------------------------------------------------------------

cmd_destroy() {
    running && cmd_stop
    rm -rf "$VM_DIR"
    info "VM de este taller destruida (la imagen base queda cacheada en $CACHE_DIR)"
}

cmd_purge() {
    cmd_destroy
    rm -rf "$CACHE_DIR"
    info "Borrada también la imagen base. El próximo 'make install' vuelve a descargarla."
}

# ---------------------------------------------------------------------

case "${1:-}" in
    install) shift; cmd_install "$@" ;;
    start)   shift; cmd_start "$@" ;;
    stop)    shift; cmd_stop "$@" ;;
    status)  shift; cmd_status "$@" ;;
    exec)    shift; cmd_exec "$@" ;;
    run)     shift; cmd_run "$@" ;;
    shell)   shift; cmd_shell "$@" ;;
    destroy) shift; cmd_destroy "$@" ;;
    purge)   shift; cmd_purge "$@" ;;
    *)
        echo "uso: $0 {install|start|stop|status|exec CMD|run CMD|shell|destroy|purge}" >&2
        exit 1
        ;;
esac
