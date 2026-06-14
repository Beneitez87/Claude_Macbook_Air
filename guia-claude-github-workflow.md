# Guía de Trabajo con Claude + GitHub entre Dispositivos

> Flujo de trabajo para mantener un proyecto sincronizado entre tu MacBook Air y tu PC de sobremesa Windows, usando GitHub como repositorio central.

---

## 📋 Prerrequisitos (configuración única)

Esta sección solo debe completarse **una vez por dispositivo**.

### En ambos dispositivos

1. **Instalar Git**
   - **Mac**: viene preinstalado. Verifica con `git --version` en Terminal.
   - **Windows**: descarga desde [git-scm.com](https://git-scm.com/download/win).

2. **Configurar identidad Git** (solo la primera vez):
   ```bash
   git config --global user.name "Tu Nombre"
   git config --global user.email "tu@email.com"
   ```

3. **Autenticación con GitHub**
   - Recomendado: instalar [GitHub CLI](https://cli.github.com/) y ejecutar `gh auth login`.
   - Alternativa visual: instalar [GitHub Desktop](https://desktop.github.com/).

4. **Crear el repositorio en GitHub** (solo una vez, desde cualquier dispositivo):
   - Ve a [github.com/new](https://github.com/new)
   - Asigna un nombre al repositorio (ej. `mi-proyecto-claude`)
   - Marca como privado si el contenido es sensible
   - Crea el repositorio

---

## 🚀 Primera vez en un dispositivo nuevo

Cuando vayas a usar un dispositivo por primera vez con un proyecto ya existente en GitHub:

### 1. Clonar el repositorio

Abre Terminal (Mac) o PowerShell/Git Bash (Windows) y ejecuta:

```bash
cd ~/Documents          # o la carpeta donde quieras alojar el proyecto
git clone https://github.com/tu-usuario/mi-proyecto-claude.git
cd mi-proyecto-claude
```

### 2. Configurar el proyecto en Cowork

1. Abre el cliente de escritorio de Claude
2. Ve a la pestaña **Cowork** en la barra lateral
3. Crea un nuevo proyecto o importa uno existente
4. Cuando solicite carpeta de trabajo, selecciona la carpeta recién clonada
5. Añade las instrucciones del proyecto si lo deseas

---

## 🔄 Flujo diario de trabajo

### Al INICIAR una sesión de trabajo

Sea cual sea el dispositivo que vayas a usar, siempre:

```bash
cd ~/Documents/mi-proyecto-claude   # ruta a tu proyecto
git pull
```

Esto descarga cualquier cambio realizado desde el otro dispositivo. **Imprescindible** para evitar conflictos.

Luego abre Cowork y continúa donde lo dejaste.

### Al FINALIZAR una sesión de trabajo

Cuando termines (sea porque cambias de dispositivo, sea porque acabas la jornada):

```bash
cd ~/Documents/mi-proyecto-claude
git status                          # ver qué archivos han cambiado
git add .                           # añadir todos los cambios
git commit -m "Descripción breve del trabajo realizado"
git push
```

---

## 📐 Comandos Git esenciales — referencia rápida

| Comando | Qué hace |
|---|---|
| `git status` | Muestra qué archivos han cambiado |
| `git pull` | Descarga cambios del repositorio remoto |
| `git add .` | Añade todos los archivos modificados al próximo commit |
| `git commit -m "mensaje"` | Guarda un punto de control con descripción |
| `git push` | Sube los commits a GitHub |
| `git log --oneline` | Muestra historial resumido de commits |

---

## 🧭 Ejemplo de sesión completa

**Lunes por la mañana — desde el MacBook Air:**

```bash
cd ~/Documents/mi-proyecto-claude
git pull
```
→ Abro Cowork, trabajo dos horas en mi proyecto.

```bash
git add .
git commit -m "Añadidos esquemas iniciales del módulo de autenticación"
git push
```

**Lunes por la tarde — desde el PC de sobremesa:**

```bash
cd C:\Users\tu-usuario\Documents\mi-proyecto-claude
git pull
```
→ Aparecen los cambios del MacBook automáticamente. Sigo trabajando.

```bash
git add .
git commit -m "Implementadas pruebas unitarias del módulo"
git push
```

---

## ⚠️ Advertencias importantes

### Cosas que GitHub NO sincroniza

- **La configuración del proyecto Cowork** — debes recrear el proyecto en cada dispositivo apuntando a la carpeta clonada.
- **El historial de conversaciones con Claude** — esto está en la nube de Claude, accesible desde cualquier dispositivo al iniciar sesión.
- **Archivos en `.gitignore`** — Git ignora los archivos listados en este fichero.

### Buenas prácticas

1. **Siempre `git pull` antes de empezar a trabajar.** Evita conflictos.
2. **Commits descriptivos.** "Cambios" no es útil; "Refactorizado módulo de pagos" sí lo es.
3. **Commits frecuentes.** Mejor 10 commits pequeños que 1 enorme.
4. **No guardes secretos** (API keys, contraseñas) en el repositorio. Usa archivos `.env` añadidos a `.gitignore`.

### Crear un .gitignore básico

Crea un archivo llamado `.gitignore` en la raíz del proyecto:

```
# Variables de entorno
.env
.env.local

# Sistemas operativos
.DS_Store
Thumbs.db

# IDE / Editor
.vscode/
.idea/

# Dependencias (ajustar según lenguaje)
node_modules/
__pycache__/
venv/
```

---

## 🆘 Solución de problemas comunes

### "Tengo cambios sin commit y quiero hacer pull"

```bash
git stash           # guardar cambios temporalmente
git pull            # traer cambios remotos
git stash pop       # recuperar tus cambios encima
```

### "Hay un conflicto al hacer pull"

Git te indicará qué archivos tienen conflicto. Ábrelos, busca las marcas `<<<<<<<`, `=======` y `>>>>>>>`, decide qué versión conservar, elimina las marcas y guarda. Luego:

```bash
git add .
git commit -m "Resuelto conflicto en X"
git push
```

### "Olvidé hacer pull y trabajé sobre versión antigua"

```bash
git pull --rebase
```

Si hay conflictos, los resuelves como arriba.

---

## 📝 Resumen de bolsillo

**Al empezar:** `git pull`
**Al terminar:** `git add .` → `git commit -m "..."` → `git push`

Eso es todo lo que necesitas recordar para el día a día, señor.
