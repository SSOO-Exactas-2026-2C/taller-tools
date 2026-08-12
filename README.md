# taller-tools

> Si sos alumnx, probablemente querés leer [VM.md](./VM.md) y el `README.md` dentro
> del taller que estás haciendo.

Herramientas compartidas por todos los talleres de Sistemas Operativos (FCEyN / UBA).

**Este repo no se clona a mano.** Cada taller se lo baja solo a su carpeta
`tools/` la primera vez que el alumno corre `make`.

## Qué hay acá

| Archivo | Para quién | Qué es |
|---|---|---|
| `vm.sh` | — | Gestión de la VM de qemu: descarga, provisión, arranque, ssh. No sabe nada de los ejercicios de ningún taller. |
| `vm.mk` | cátedra | Los targets de make genéricos (`install`, `start-vm`, etc). Lo incluye el `Makefile` de cada taller. |
| `cloud-init/` | — | Plantilla de configuración del guest: usuario, clave ssh, carpeta compartida, paquetes. |
| `VM.md` | alumnos | La documentación del entorno. El `README.md` de cada taller la linkea. |

## Cómo funciona

Todo se compila y se ejecuta adentro de una VM Debian 12 x86_64, no en la máquina
del alumno, así el entorno es idéntico en Linux, macOS (Intel y Apple Silicon) y
Windows con WSL2.

Hay dos niveles de imagen:

1. Una imagen **base**, que se descarga y provisiona una sola vez **por
   host** y queda cacheada en `~/.local/share/taller-so`, compartida entre
   todos los talleres.
2. Un **overlay por taller** (`<taller>/vm/taller.qcow2`), de unos pocos MB.

La carpeta del taller se comparte con el guest por 9p y se monta en `/taller`.
Cada taller busca solo un puerto ssh libre, así que se pueden tener varias VMs
prendidas al mismo tiempo.

> **La lista de paquetes de `cloud-init/user-data.tpl` es un contrato entre
> todos los talleres.** La imagen base la configura el primer taller que corra
> `make install` en esa máquina, y después la reusan los demás. Si un taller
> necesita un paquete nuevo, se agrega acá y lo tienen todos; agregarlo en un
> taller solo no funcionaría.

## Enganchar un taller

En el `Makefile` del taller, al principio:

```make
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------
# Herramientas compartidas por todos los talleres de la materia (la VM,
# principalmente). Viven en su propio repo y las baja make solo, la primera
# vez.  https://github.com/SSOO-Exactas-2026-2C/taller-tools
TOOLS_REPO ?= https://github.com/SSOO-Exactas-2026-2C/taller-tools.git
TOOLS_REF  ?= main

# Se clona en una carpeta temporal y recién ahí se mueve a tools/, para que un
# Ctrl-C a mitad de la descarga no deje un tools/ incompleto (que después haría
# fallar todos los clones siguientes con "destination path already exists").
#
# Ojo: el resultado se chequea con el exit status del $(shell) y NO con un
# segundo $(wildcard). Make cachea el listado de cada directorio y no lo
# invalida después de un $(shell), así que el wildcard seguiría dando vacío y
# abortaría un clone que en realidad anduvo bien.
ifeq ($(wildcard tools/vm.mk),)
$(info ==> Bajando las herramientas compartidas del taller...)
TOOLS_OK := $(shell rm -rf tools tools.tmp && \
	git clone --quiet --depth 1 --branch $(TOOLS_REF) $(TOOLS_REPO) tools.tmp 1>&2 && \
	mv tools.tmp tools && echo ok)
ifneq ($(TOOLS_OK),ok)
$(error No pude bajar las herramientas del taller desde $(TOOLS_REPO) -- necesitás git y conexión a internet)
endif
endif

include tools/vm.mk
```

Y después:

- En `.gitignore` del taller: `/tools/` y `/tools.tmp/`.
- En el target `help`, intercalar `$(VM_HELP)` y `$(VM_HELP_LIMPIEZA)` entre los
  bloques propios del taller.
- En los targets `strace-*`, usar `$(VM_SHOW_TRACE)` como epílogo (necesita que
  el taller defina `FILTRO`).
- En los `run-*` y `strace-*`, terminar con `$(INTERACTIVO)`.
- En el `README.md` del taller, linkear
  `https://github.com/SSOO-Exactas-2026-2C/taller-tools/blob/main/VM.md` en vez
  de un `VM.md` local.

Lo que **no** hay que hacer: definir `install`, `start-vm`, `stop-vm`,
`vm-status`, `shell`, `clean-vm` ni `purge-vm`, ni declararlos en el `.PHONY`.
Ya vienen de `vm.mk`.

## Trabajar sobre este repo

Los talleres clonan este repo en el branch `main`. **Un push acá le llega
a los 5 talleres**, así que conviene probar el cambio contra al menos un taller
real antes de pushear:

```bash
cd ../taller-syscalls-template
rm -rf tools && make help TOOLS_REPO=../taller-tools TOOLS_REF=main
make start-vm && make test
```

Del lado del alumno, `make update-tools` trae la última versión.
