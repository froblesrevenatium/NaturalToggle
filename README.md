# Auto Scroll Mode Changer

Cambia automáticamente el **Desplazamiento natural** de macOS según el mouse:

| Mouse        | Desplazamiento natural |
|--------------|------------------------|
| Conectado    | Apagado                |
| Desconectado | Encendido              |

Corre en segundo plano como LaunchAgent y arranca al iniciar sesión.

## Ícono en la barra de menús

Mientras el servicio corre aparece un ícono de mouse en la barra de menús; si no aparece, el servicio no está corriendo.

- Relleno: mouse conectado (desplazamiento natural apagado).
- Contorno atenuado: mouse desconectado (desplazamiento natural encendido).

El menú muestra el estado del mouse, el del desplazamiento natural, el vendor/product vigilado y las opciones:

- **Configurar…** abre `Auto Scroll Mode.app` (debe haberse abierto al menos una vez para que macOS la encuentre).
- **Salir** detiene el servicio hasta el próximo inicio de sesión. Para volver a iniciarlo: **Usar este mouse** en la app o `make install`.

Si el servicio se cierra por un error, launchd lo reinicia solo. Si el ícono no aparece con el servicio activo, revisa que esté permitido en Configuración del Sistema → Barra de menús.

## Cambiar de mouse con la app (recomendado)

1. Conecta el mouse nuevo.
2. Abre `Auto Scroll Mode.app` (en este directorio). Si no existe, créala con `make app`.
3. Selecciona el mouse en la tabla y pulsa **Usar este mouse**.

La app muestra:

- El estado del servicio (verde activo, rojo detenido) y el vendor/product configurados.
- Los mouse conectados; el configurado lleva una palomita verde.
- Las últimas líneas del registro.

**Desinstalar** detiene el servicio y borra el LaunchAgent y el binario.

Si macOS bloquea la app la primera vez: clic derecho → **Abrir**.

## Cambiar de mouse desde la terminal

1. Obtén el vendor y product del mouse:

   ```sh
   ioreg -r -c IOHIDDevice -l | grep -E '"(Product|VendorID|ProductID|PrimaryUsage)" '
   ```

   El mouse es el que tiene `PrimaryUsage = 2`. También los muestra la app.

2. Instala con esos valores:

   ```sh
   make install VENDOR=2821 PRODUCT=6304
   ```

## Comandos

| Comando                              | Qué hace                                            |
|--------------------------------------|-----------------------------------------------------|
| `make build`                         | Compila el servicio                                 |
| `make app`                           | Compila `Auto Scroll Mode.app` (incluye el servicio) |
| `make install VENDOR=… PRODUCT=…`    | Instala o actualiza el servicio para ese mouse      |
| `make uninstall`                     | Detiene y elimina el servicio                       |
| `make logs`                          | Muestra el registro en vivo                         |

## Archivos

| Archivo                | Descripción                                             |
|------------------------|---------------------------------------------------------|
| `main.swift`           | Servicio que vigila el mouse, cambia el ajuste y muestra el ícono en la barra de menús |
| `gui.swift`            | App para elegir el mouse e instalar el servicio         |
| `Info.plist`           | Metadatos de la app                                     |
| `launchagent.plist.in` | Plantilla del LaunchAgent que usa `make install`        |
| `Makefile`             | Compilación, instalación y desinstalación               |

Rutas instaladas:

- Binario: `~/.local/bin/auto-scrollmode-changer`
- LaunchAgent: `~/Library/LaunchAgents/com.fernandorobles.auto-scrollmode-changer.plist`
- Registro: `~/Library/Logs/auto-scrollmode-changer.log`

## Notas

- **Arranque:** inicia al entrar a tu sesión, no en la pantalla de login. Aparece en Configuración del Sistema → General → Ítems de inicio y extensiones; si lo desactivas ahí, no arranca.
- **Receptor inalámbrico:** "conectado" significa que el receptor USB está puesto. Apagar el mouse sin quitar el receptor cuenta como conectado.
- **Trackpad:** macOS usa un solo ajuste para trackpad y mouse; ambos cambian.
- **API privada:** el cambio en vivo usa `setSwipeScrollDirection` de `PreferencePanesSupport.framework`. Una actualización de macOS podría quitarla; en ese caso el registro mostrará `setSwipeScrollDirection no disponible`.
- **Permisos:** la detección usa notificaciones de IOKit y no requiere Monitoreo de entrada ni Accesibilidad.
