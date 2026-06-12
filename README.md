# Sistema de asignación de taxis

Proyecto en Elixir/Phoenix y React para simular la asignación de taxis a un cliente.

El trabajo está dividido en tres versiones:

- `v1`: versión base trabajada en clase.
- `v2`: contacta a tres conductores al mismo tiempo y espera 1.5 minutos.
- `v3`: agrega cancelaciones, penalización, llegada del taxi y registro de servicios no exitosos.

## Estructura

```text
taxi_26_elixir/
|-- v1/
|   |-- taxi_be/
|   `-- taxi_fe/
|-- v2/
|   |-- taxi_be/
|   `-- taxi_fe/
`-- v3/
    |-- taxi_be/
    `-- taxi_fe/
```

## Versión recomendada

La versión final es `v3`.

Incluye:

- solicitud de viaje por cliente;
- contacto simultáneo a tres conductores;
- aceptación por el primer conductor que responda;
- limpieza de tarjetas de conductores después de aceptar;
- contador de llegada actualizado cada 30 segundos;
- cancelación antes y después de aceptación;
- penalización de `$20` si se cancela cuando faltan 3 minutos o menos;
- archivo `service_log.txt` para registrar servicios no exitosos;
- botón de prueba `Time skip` para avanzar el contador 45 segundos.

## Ejecutar backend

Desde una terminal:

```powershell
cd v3\taxi_be
mix deps.get
mix phx.server
```

El backend corre en:

```text
http://localhost:4000
```

Si abres esa URL en el navegador y aparece `NoRouteError`, es normal. El backend no tiene página principal; solo expone API y sockets.

## Ejecutar frontend

Desde otra terminal:

```powershell
cd v3\taxi_fe
npm install
npm run dev
```

El frontend normalmente corre en:

```text
http://localhost:5173
```

## Flujo principal en v3

1. El cliente manda una solicitud.
2. El backend contacta a tres conductores.
3. Los conductores reciben una tarjeta con la solicitud.
4. El primer conductor que acepta gana el viaje.
5. Las demás tarjetas se limpian.
6. El cliente ve el taxi asignado y el ETA.
7. El ETA baja cada 30 segundos.
8. El cliente puede cancelar mientras el taxi va en camino.
9. Si cancela tarde, se aplica penalización.
10. Si el taxi llega, se notifica el inicio del viaje.

## Registro de servicios

Los servicios que no terminan exitosamente se registran en:

```text
v3/taxi_be/service_log.txt
```

Este archivo se crea automáticamente cuando ocurre el primer caso no exitoso.

## Notas

- `node_modules`, `_build`, `deps` y otros archivos generados están ignorados por Git.
- La solución mantiene cada versión separada para que sea fácil revisar la evolución.
- El archivo de log es intencionalmente simple. Para producción sería mejor usar base de datos.

## Repositorio

Liga del repositorio:

```text
PEGAR_AQUI_LA_LIGA_DEL_REPOSITORIO
```
