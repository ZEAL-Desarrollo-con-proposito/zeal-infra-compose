#!/bin/sh
# Primario: al crear el volumen ejecuta, en orden, el rol de la aplicación (R2-14, común al resto de los
# despliegues) y el rol de replicación. Se usa un solo archivo porque Docker no permite montar archivos
# dentro de un directorio que ya se montó de solo lectura.
set -eu
sh /init/app/01-app-role.sh
sh /init/02-replication.sh
