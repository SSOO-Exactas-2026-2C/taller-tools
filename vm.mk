# Targets genéricos de la VM, compartidos por todos los talleres de SSOO.
#
# Este archivo vive en el repo taller-tools y lo incluye el Makefile de cada
# taller. Acá va todo lo que no depende de los ejercicios; lo específico de
# cada taller (build-*, run-*, test-*, FILTRO, ...) vive en su Makefile.
#
# Ver README.md de este repo para saber cómo engancharlo desde un taller.

# Carpeta donde quedó clonado este repo, derivada de la ruta de este mismo
# archivo (MAKEFILE_LIST apunta acá mientras se lo parsea). Así el taller lo
# puede clonar donde quiera sin que se rompa nada.
VM_TOOLS_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

# WORKSHOP_DIR es la carpeta que se comparte con la VM por 9p: la del taller,
# no la de este repo. vm.sh no la puede deducir sola, porque vive adentro.
VM := WORKSHOP_DIR='$(CURDIR)' bash $(VM_TOOLS_DIR)/vm.sh

# Defaults que cada taller puede pisar.
CFLAGS    ?= -Wall -Wextra -std=gnu11 -D_GNU_SOURCE -g
TRACE_LOG ?= trace.txt

# Rama de este repo que sigue el taller. Normalmente ya viene definida desde el
# Makefile del taller (es la que usó para clonar); el default es por si no.
TOOLS_REF ?= main

# Los run-* y strace-* son interactivos y se cortan con Ctrl-C o Ctrl-D. Cuando
# el programa de adentro de la VM muere por una señal, ssh no tiene forma de
# representar eso en un código de salida y devuelve 255. No es un error del
# taller, así que se lo perdonamos a make:
#
#   run-ej1: build-ej1
#           @$(VM) run "./$(BIN_EJ1)" $(INTERACTIVO)
#
# Ojo: SOLO en esos targets. Los test-* también pasan por ssh, y ahí el código
# de salida sí importa, es el resultado de las pruebas.
INTERACTIVO = ; rc=$$?; test $$rc -eq 255 || exit $$rc

.PHONY: install start-vm stop-vm vm-status shell clean-vm purge-vm update-tools

install:   ; @$(VM) install
start-vm:  ; @$(VM) start
stop-vm:   ; @$(VM) stop
vm-status: ; @$(VM) status
shell:     ; @$(VM) shell
clean-vm:  ; @$(VM) destroy
purge-vm:  ; @$(VM) purge

# Trae la última versión de las herramientas compartidas. Es un reset --hard
# a propósito: tools/ no es para editar a mano, es un clon administrado.
update-tools:
	@echo "==> Actualizando las herramientas compartidas..."
	@git -C $(VM_TOOLS_DIR) fetch --quiet --depth 1 origin $(TOOLS_REF)
	@git -C $(VM_TOOLS_DIR) reset --quiet --hard origin/$(TOOLS_REF)
	@echo "==> Listo: $$(git -C $(VM_TOOLS_DIR) log -1 --format='%h %s')"

# ---------------------------------------------------------------------
# Canned recipes: se expanden adentro de un target del Makefile del taller.
# Ojo al editarlas: las líneas de acá adentro NO llevan tab, se lo agrega make
# al expandirlas en el contexto de una receta.
# ---------------------------------------------------------------------

# Bloque "Puesta en marcha" del help, igual en todos los talleres.
define VM_HELP
@echo "  Puesta en marcha"
@echo "    make install              instala lo que falte y prepara la VM (una sola vez)"
@echo "    make start-vm             levanta la VM"
@echo "    make stop-vm              apaga la VM"
@echo "    make vm-status            estado de la VM"
@echo "    make shell                abre una terminal adentro de la VM"
endef

# Bloque "Limpieza" del help. El taller define qué borra su propio "make clean".
define VM_HELP_LIMPIEZA
@echo "  Limpieza"
@echo "    make clean                borra los binarios compilados"
@echo "    make clean-vm             destruye la VM de este taller"
@echo "    make purge-vm             además borra la imagen descargada"
@echo "    make update-tools         actualiza las herramientas compartidas"
endef

# Epílogo de los targets strace-*: dice dónde quedó la traza completa y muestra
# lo filtrado. Usa TRACE_LOG y FILTRO, que define cada taller: como esta
# variable es recursiva, se resuelven recién al expandirla, no acá.
define VM_SHOW_TRACE
@echo ""
@echo "--- traza completa en $(TRACE_LOG) ---"
@echo "--- filtrando por: $(FILTRO) ---"
@echo ""
@grep -E '$(FILTRO)' $(TRACE_LOG) || echo "(el filtro no encontró nada)"
endef
