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

## Versión final

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