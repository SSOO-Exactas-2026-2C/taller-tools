#cloud-config
#
# Configuración inicial de la VM de los talleres de Sistemas Operativos.
#
# Esto se aplica UNA sola vez, cuando "make install" prepara la imagen base.
# Después queda todo horneado en la imagen y los talleres arrancan sin
# volver a pasar por cloud-init.
#
# Los @PLACEHOLDERS@ los reemplaza tools/vm.sh antes de armar el ISO.

hostname: taller-so

users:
  - name: @GUEST_USER@
    # El uid del guest se hace coincidir con el del host: la carpeta
    # compartida se monta con security_model=none, así que los archivos
    # conservan el uid del host y de esta forma se pueden editar y
    # compilar de los dos lados sin problemas de permisos.
    uid: "@HOST_UID@"
    shell: /bin/bash
    groups: [sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: false
    plain_text_passwd: "@GUEST_PASS@"
    ssh_authorized_keys:
      - "@SSH_PUBKEY@"

# Habilitamos también la clave por si alguien quiere entrar a mano. La VM
# solo escucha en 127.0.0.1, no está expuesta a la red.
ssh_pwauth: true

write_files:
  # El módulo 9p es el que habla con la carpeta compartida de qemu.
  - path: /etc/modules-load.d/9p.conf
    content: |
      9p
      9pnet
      9pnet_virtio

bootcmd:
  - modprobe 9pnet_virtio || true

# Carpeta compartida con el host. "nofail" es importante: la imagen base
# tiene que poder bootear aunque qemu no le pase la carpeta (por ejemplo
# durante esta misma provisión).
mounts:
  - [ "@MOUNT_TAG@", "@GUEST_DIR@", "9p", "trans=virtio,version=9p2000.L,rw,nofail,msize=512000", "0", "0" ]

# La VM corre con 512 MB de RAM; un poco de swap evita sorpresas.
swap:
  filename: /swapfile
  size: 536870912

# OJO: esta lista tiene que ser IDENTICA en todos los talleres. La imagen
# base se cachea y se comparte entre todos, y la hornea el primer taller
# que corra "make install"; si un taller pidiera un paquete de mas, no lo
# tendria cuando el alumno arranco por otro.
package_update: true
packages:
  # Para compilar y correr los ejercicios.
  - gcc
  - libc6-dev
  - make
  - python3
  # Para espiar que hace un proceso: syscalls, procesos vivos, fds abiertos.
  - strace
  - binutils
  - procps
  - psmisc
  - lsof
  - gdb
  # Para hablarle a mano a un servidor de sockets (taller de IPC).
  - netcat-openbsd
  # Para poder consultar "man 2 fork" y companía adentro de la VM.
  - man-db
  - manpages-dev

runcmd:
  # Al entrar por ssh, quedar parado en la carpeta del taller.
  - [ sh, -c, "echo 'cd @GUEST_DIR@ 2>/dev/null || true' >> /home/@GUEST_USER@/.bashrc" ]
  - [ chown, "@GUEST_USER@:@GUEST_USER@", "/home/@GUEST_USER@/.bashrc" ]
  # Sin esto, systemd espera 90s a la red en cada arranque.
  - [ systemctl, disable, systemd-networkd-wait-online.service ]

final_message: "VM del taller lista"
