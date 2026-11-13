# autopatcher
autopatch apks

Links de Obtainium para mis builds.

<!-- OBTAINIUM_LINKS_START -->
## 📲 Instalar con Obtainium

Añade cualquiera de estas apps a Obtainium con un solo toque (móvil) o manualmente (TV).

### 📺 Añadir manualmente (especial para Android TV)
Los enlaces directos (`obtainium://`) no siempre funcionan en Android TV. Para añadir una app manualmente:
1. Abre Obtainium en tu TV y pulsa **+** (Añadir App).
2. Pega esta URL como fuente:
```text
https://github.com/joelmzj/autopatcher
```
3. Selecciona la fuente **GitHub**.
4. Ve a **Ajustes Avanzados** de la app y configura lo siguiente:
   - **Filter APKs by regular expression**: Pega la cadena regex específica de la app (ver tabla abajo).
   - **Version detection**: Desactivado (OFF).
   - **Release date as version**: Activado (ON).
   - **Use latest asset upload date as release date**: Activado (ON).
   - **Attempt to filter APKs by CPU architecture if possible**: Activado (ON).
5. Guarda la app.

> **Nota:** Si notas que un ID de paquete ha cambiado repentinamente (por ejemplo, por un nuevo parche de clonación), significa que el desarrollador ha modificado el paquete base. Revisa la configuración de esa app.

---

### Instagram (`com.instagram.android`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.instagram.android%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Instagram%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EInstagram-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Instagram-
```

### Telegram (`org.telegram.messenger.web`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522org.telegram.messenger.web%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Telegram%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255ETelegram-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Telegram-
```

### Pinterest (`com.pinterest`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.pinterest%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Pinterest%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EPinterest-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Pinterest-
```

### Messenger (`com.facebook.orca`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.facebook.orca%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Messenger%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EMessenger-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Messenger-
```

### Facebook (`com.facebook.katana`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.facebook.katana%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Facebook%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EFacebook-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Facebook-
```

### TikTok (`com.zhiliaoapp.musically`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.zhiliaoapp.musically%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522TikTok%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255ETikTok-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^TikTok-
```

### YouTubeMusic-Morphe (`app.morphe.android.apps.youtube.music`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522app.morphe.android.apps.youtube.music%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522YouTubeMusic-Morphe%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EYouTubeMusic-Morphe-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^YouTubeMusic-Morphe-
```

### YouTubeMusic-anddea (`anddea.youtube.music`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522anddea.youtube.music%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522YouTubeMusic-anddea%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EYouTubeMusic-anddea-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^YouTubeMusic-anddea-
```

### YouTube-Morphe (`app.morphe.android.youtube`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522app.morphe.android.youtube%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522YouTube-Morphe%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EYouTube-Morphe-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^YouTube-Morphe-
```

### YouTube-anddea (`anddea.youtube`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522anddea.youtube%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522YouTube-anddea%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EYouTube-anddea-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^YouTube-anddea-
```

### YouTube-Tablet-Morphe (`app.morphe.android.youtube`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522app.morphe.android.youtube%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522YouTube-Tablet-Morphe%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EYouTube-Tablet-Morphe-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^YouTube-Tablet-Morphe-
```

### YouTube-Tablet-anddea (`anddea.youtube`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522anddea.youtube%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522YouTube-Tablet-anddea%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EYouTube-Tablet-anddea-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^YouTube-Tablet-anddea-
```

### X (`com.twitter.android`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.twitter.android%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522X%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EX-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^X-
```

### Google-Photos (`app.morphe.android.apps.photos`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522app.morphe.android.apps.photos%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Google-Photos%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EGoogle-Photos-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Google-Photos-
```

### Projectivy-Launcher (`com.spocky.projengmenu`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.spocky.projengmenu%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Projectivy-Launcher%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EProjectivy-Launcher-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Projectivy-Launcher-
```

### TizenTube-Youtube-original (`com.google.android.youtube.tv`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.google.android.youtube.tv%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522TizenTube-Youtube-original%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255ETizenTube-Youtube-original-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^TizenTube-Youtube-original-
```

### Spotify-myspoti (`app.myspoti.stable`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522app.myspoti.stable%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Spotify-myspoti%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255ESpotify-myspoti-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Spotify-myspoti-
```

### Stremio-TV (`com.stremio.one`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.stremio.one%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Stremio-TV%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EStremio-TV-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Stremio-TV-
```

### Stremio-Phone (`com.stremio.one`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.stremio.one%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Stremio-Phone%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EStremio-Phone-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Stremio-Phone-
```

### Vix-TV (`com.univision.prendetv`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.univision.prendetv%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522Vix-TV%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255EVix-TV-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^Vix-TV-
```

### SendFilesToTV-TV (`com.yablio.sendfilestotv`)
- **Enlace directo (móvil):** [Añadir a Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.yablio.sendfilestotv%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fjoelmzj%252Fautopatcher%2522%252C%2522author%2522%253A%2522joelmzj%2522%252C%2522name%2522%253A%2522SendFilesToTV-TV%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522useLatestAssetDateAsReleaseDate%255C%2522%253Atrue%252C%255C%2522releaseDateAsVersion%255C%2522%253Atrue%252C%255C%2522versionDetection%255C%2522%253Afalse%252C%255C%2522autoApkFilterByArch%255C%2522%253Atrue%252C%255C%2522apkFilterRegEx%255C%2522%253A%255C%2522%255ESendFilesToTV-TV-%255C%2522%257D%2522%257D)
- **Cadena regex (manual):**
```text
^SendFilesToTV-TV-
```

---
> **Nota:** Solo se instalan los APKs (no los módulos).
<!-- OBTAINIUM_LINKS_END -->