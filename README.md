# proyecto3d

Proyecto Flutter para convertir fotos en elementos 3D.

## Estructura

- `lib/`: aplicacion Flutter.
- `server/`: API local en Dart para recibir fotos y orquestar la conversion a 3D.

## Idea de arquitectura

1. Flutter toma o selecciona una foto.
2. La app envia la imagen al backend.
3. El backend crea un job de conversion.
4. El backend devuelve el estado del job.
5. Cuando termina, Flutter descarga o muestra el modelo 3D.

## Backend

El backend ya esta preparado para conectarse con Meshy mediante `MESHY_API_KEY`.

Para correrlo:

```powershell
$env:MESHY_API_KEY="pega_aqui_tu_api_key"
```

```bash
cd server
dart pub get
dart run bin/server.dart
```

Los detalles estan en `server/README.md`.

## Nota importante

La app Flutter ya puede:

- elegir una imagen,
- enviarla al backend,
- consultar el progreso del job,
- y mostrar la URL del `.glb` generado por Meshy.

Lo que falta para una experiencia mas completa es renderizar ese `.glb` dentro de Flutter.

## Deploy recomendado

La forma mas comoda para no depender de terminal local es subir el backend a Render.

El repo ya incluye:

- `render.yaml` para crear el servicio web
- `server/Dockerfile` para construir el backend
- soporte para `PORT` en el servidor

Una vez desplegado, puedes arrancar Flutter apuntando a la URL publica:

```bash
flutter run -d chrome --dart-define=API_BASE_URL=https://tu-servicio.onrender.com
```

Si luego generas un build, puedes usar el mismo `--dart-define` para dejar fija la URL del backend.
