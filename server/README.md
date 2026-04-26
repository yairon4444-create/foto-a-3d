# API local para foto a 3D

Este backend reenvia la imagen a **Meshy Image to 3D** y devuelve el estado del trabajo para que Flutter lo consulte.

## Requisito

Necesitas una API key de Meshy.

Documentacion oficial:

- [Meshy Authentication](https://docs.meshy.ai/en/api/authentication)
- [Meshy Image to 3D](https://docs.meshy.ai/en/api/image-to-3d)

## Correr el servidor

Primero carga tu API key en PowerShell:

```powershell
$env:MESHY_API_KEY="pega_aqui_tu_api_key"
```

Luego:

```bash
cd server
dart pub get
dart run bin/server.dart
```

La API queda en `http://localhost:8080`.

## Deploy en Render

Este repo ya incluye:

- `../render.yaml`
- `Dockerfile`

Pasos:

1. Sube este proyecto a GitHub.
2. En Render, crea un nuevo Blueprint o Web Service desde ese repo.
3. Si usas el `render.yaml`, Render detecta el servicio `proyecto3d-api`.
4. Cuando Render pida secretos, coloca `MESHY_API_KEY`.
5. Al terminar el deploy, obtendras una URL como `https://proyecto3d-api.onrender.com`.

El servidor ya lee `PORT`, que es necesario en plataformas como Render.

## Verificar configuracion

```bash
curl http://localhost:8080/health
```

Debe aparecer:

```json
{
  "meshyConfigured": true
}
```

## Endpoints

### `GET /health`

Devuelve estado del backend y si Meshy esta configurado.

### `POST /v1/jobs`

Recibe JSON con una imagen en Base64:

```json
{
  "fileName": "mesa.jpg",
  "prompt": "wooden table, high detail",
  "imageBase64": "BASE64_AQUI"
}
```

Respuesta:

```json
{
  "jobId": "meshy_task_id",
  "status": "queued",
  "message": "Image received. Processing started in Meshy."
}
```

### `GET /v1/jobs/:id`

Devuelve el estado actual del trabajo en Meshy:

```json
{
  "jobId": "meshy_task_id",
  "status": "completed",
  "createdAt": "2026-04-25T20:50:00.000",
  "completedAt": "2026-04-25T20:50:02.000",
  "modelUrl": "https://assets.meshy.ai/.../model.glb",
  "thumbnailUrl": "https://assets.meshy.ai/.../preview.png",
  "prompt": "wooden table, high detail",
  "progress": 100,
  "errorMessage": ""
}
```

## Como conectarlo con Flutter

1. El usuario selecciona una imagen.
2. Flutter lee los bytes.
3. Flutter convierte a Base64.
4. Flutter hace `POST /v1/jobs`.
5. Guarda el `jobId`.
6. Hace polling con `GET /v1/jobs/:id`.
7. Cuando llegue `completed`, usa `modelUrl` para descargar o mostrar el `.glb`.

En Flutter puedes fijar la URL publica con:

```bash
flutter run --dart-define=API_BASE_URL=https://proyecto3d-api.onrender.com
```

## Limitaciones de esta version

- Depende de una cuenta y creditos de Meshy.
- Usa Base64, que sirve para MVP pero no es ideal para archivos grandes.
- No guarda los modelos localmente; devuelve la URL remota de Meshy.
- No tiene autenticacion propia para tus usuarios.
