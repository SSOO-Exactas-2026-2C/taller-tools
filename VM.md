# Entorno de trabajo: la VM

Todo el taller se compila y se ejecuta **adentro de una máquina virtual Linux**
que levanta el propio `make`. La carpeta del taller se comparte con la VM, así
que editás los archivos con tu editor de siempre, en tu máquina, y `make` se
encarga de compilar y correr del otro lado.

Trabajamos así por dos razones:

- El entorno es **idéntico para todos** (y para la corrección), sin importar si
  usás Linux, macOS o Windows.
- Las herramientas que usamos en la materia (`strace`, `/proc`, `lsof`, las
  señales de POSIX) existen solo en Linux, y acá funcionan siempre.

Este archivo es el mismo para todos los talleres de la materia: acá está el
entorno, y el enunciado y los comandos de cada ejercicio están en el `README.md`
del taller que estés haciendo.

> Vive en el repo [taller-tools](https://github.com/SSOO-Exactas-2026-2C/taller-tools),
> junto con los scripts de la VM. La primera vez que corrés `make`, el taller se
> lo baja solo a su carpeta `tools/`. No hace falta que hagas nada.

---

## Setup

### 1. Instalar las dependencias del host

**Linux (Debian / Ubuntu)**

```bash
sudo apt install make qemu-system-x86 qemu-utils xorriso openssh-client curl
```

**macOS**

```bash
brew install qemu
```

Si no tenés Homebrew, instalalo desde [brew.sh](https://brew.sh).

**Windows**

Instalá [WSL2](https://learn.microsoft.com/windows/wsl/install) (desde
PowerShell: `wsl --install`), abrí la terminal de Ubuntu y seguí desde ahí las
instrucciones de Linux. Todo el taller se hace adentro de WSL.

### 2. Preparar la VM

```bash
make install
```

Este comando descarga la imagen de Debian (~400 MB, **una sola vez** para todos
los talleres de la materia) y la deja configurada con las herramientas que
usamos. Tarda unos minutos la primera vez.

### 3. Levantar la VM y trabajar

```bash
make start-vm     # la VM queda corriendo en segundo plano
make help         # todos los comandos disponibles
```

La VM queda prendida entre comandos, así que solo pagás el arranque una vez.
Cuando termines:

```bash
make stop-vm
```

> No hace falta levantar la VM a mano cada vez. Al intentar compilar o ejecutar
> cualquier ejercicio del taller, si la VM está apagada se prende automáticamente.

---

## Comandos generales

| Comando | Qué hace |
|---|---|
| `make install` | Crea y configura la VM (una sola vez) |
| `make start-vm` / `make stop-vm` | Prende / apaga la VM |
| `make vm-status` | Estado de la VM |
| `make shell` | Te abre una terminal adentro de la VM, parada en el taller |
| `make help` | Lista todos los comandos disponibles |
| `make build` | Compila todos los ejercicios |
| `make test` | Corre todos los tests |
| `make clean` | Borra los binarios compilados |
| `make clean-vm` | Destruye la VM de este taller (la imagen descargada queda) |
| `make purge-vm` | Además borra la imagen descargada |
| `make update-tools` | Actualiza las herramientas compartidas (`tools/`) |

Los comandos específicos de cada ejercicio están documentados en el `README.md`
del taller.

---

## Problemas comunes

**`make` dice que no pudo bajar las herramientas del taller.** La primera vez,
`make` clona el repo de herramientas en `tools/`. Necesitás `git` instalado y
conexión a internet. Si el problema persiste, borrá `tools/` y probá de nuevo.

**`make install` dice que falta qemu.** Seguí el comando que te sugiere, o
instalalo con el gestor de paquetes de tu sistema.

**La VM no arranca o `make` se queda esperando.** Mirá el log de la consola de
la VM en `vm/console.log`. Para empezar de cero sin volver a descargar la
imagen: `make clean-vm && make start-vm`.

**El puerto 2222 está ocupado.** No es problema: cada taller busca solo un
puerto libre. Podés ver cuál usa con `make vm-status`.

**Quiero borrar absolutamente todo, imagen incluida.** `make purge-vm`.

**Edito en mi máquina, ¿la VM ve los cambios?** Sí, es la misma
carpeta, compartida entre tu máquina y la VM. No hace falta copiar nada ni
reiniciar nada.

**¿Puedo tener dos talleres andando al mismo tiempo?** Sí. Cada taller levanta
su propia VM en su propio puerto, y todas comparten la misma imagen base
descargada.
