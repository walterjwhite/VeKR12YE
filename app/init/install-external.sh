#!/bin/sh

#
# Public installer for @walterjwhite/init on non-dev machines.
#
# Unlike app/init/bootstrap.sh and app/init/install.sh (development only),
# this script does not require a development checkout. It resolves the init
# app source from (in order): a git URL passed as $1, the configured registry
# gitUrl, or an existing local registry copy - then installs it.
#
# sudo is used only for privileged operations (system install dirs and bin
# links). npm/node always run as the invoking user inside a user-owned
# staging directory, so no root-owned files are ever left in $HOME.

set -e

readonly APP_NAME="init"
readonly CONFIG_FILE="$HOME/.config/walterjwhite/app/init.yml"
readonly USER_APP_DATA_DIR="$HOME/.data/app"
readonly USER_BIN_DIR="$HOME/.local/bin"
readonly SYSTEM_APP_DATA_DIR="/usr/local/share/app"
readonly SYSTEM_BIN_DIR="/usr/local/bin"

# Use sudo only when actually needed: never when already running as root.
if [ "$(id -u)" = "0" ]; then
  SUDO=""
else
  SUDO="sudo"
fi

readonly APP_PLATFORM_OS_NAME=$(uname)
case "$APP_PLATFORM_OS_NAME" in
Darwin)
  readonly APP_PLATFORM_PLATFORM="Apple"
  ;;
MINGW64_NT-* | MSYS_NT-*)
  readonly APP_PLATFORM_PLATFORM="Windows"
  ;;
*)
  readonly APP_PLATFORM_PLATFORM="$APP_PLATFORM_OS_NAME"
  ;;
esac

log() {
  echo "==> $*"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# Ensure required tools exist. Installing system packages is one of the few
# legitimate uses of sudo here.
ensure_node() {
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    case "$APP_PLATFORM_PLATFORM" in
    FreeBSD)
      $SUDO pkg install -y npm
      ;;
    Arch | CachyOS)
      $SUDO pacman -S --noconfirm nodejs npm || $SUDO pacman -S --noconfirm node
      ;;
    *)
      die "Unsupported platform for auto-install: '$APP_PLATFORM_PLATFORM'. Please install Node.js and npm first."
      ;;
    esac
  fi
}

ensure_git() {
  if ! command -v git >/dev/null 2>&1; then
    case "$APP_PLATFORM_PLATFORM" in
    FreeBSD)
      $SUDO pkg install -y git
      ;;
    Arch | CachyOS)
      $SUDO pacman -S --noconfirm git
      ;;
    *)
      die "git is required but not installed."
      ;;
    esac
  fi
}

# Resolve the registry repository URL: explicit override or from the init config.
resolve_repo_url() {
  if [ -n "${1:-}" ]; then
    REPO_URL="$1"
  elif [ -f "$CONFIG_FILE" ]; then
    REPO_URL="$(awk '
      /^registries:/{reg=1; next}
      reg && /^[[:space:]]+default:/{def=1; next}
      def && /gitUrl:/{
        sub(/^.*gitUrl:[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        print
        exit
      }
    ' "$CONFIG_FILE")"
  else
    REPO_URL=""
  fi
}

# Resolve the app source directory.
resolve_app_source() {
  LOCAL_REGISTRY="$USER_APP_DATA_DIR/registry/default"

  if [ -d "$LOCAL_REGISTRY/$APP_NAME" ] && [ -f "$LOCAL_REGISTRY/$APP_NAME/package.json" ]; then
    APP_SRC="$LOCAL_REGISTRY/$APP_NAME"
    log "Using local registry: $APP_SRC"
  elif [ -n "${REPO_URL:-}" ] && [ "$REPO_URL" != "null" ]; then
    if [ -d "$REPO_URL/$APP_NAME" ] && [ -f "$REPO_URL/$APP_NAME/package.json" ]; then
      APP_SRC="$REPO_URL/$APP_NAME"
      log "Using local directory source: $APP_SRC"
    elif [ -d "$REPO_URL" ] && [ -f "$REPO_URL/package.json" ]; then
      APP_SRC="$REPO_URL"
      log "Using local directory source: $APP_SRC"
    else
      TEMP_CLONE_DIR=$(mktemp -d)
      chmod 755 "$TEMP_CLONE_DIR"
      log "Cloning repository to temporary location..."
      if git -c safe.directory='*' clone "$REPO_URL" "$TEMP_CLONE_DIR"; then
        APP_SRC="$TEMP_CLONE_DIR"

        # Search remote branches if package.json is missing on default checkout
        if [ ! -f "$APP_SRC/package.json" ] && [ ! -f "$APP_SRC/$APP_NAME/package.json" ] && [ ! -f "$APP_SRC/app/$APP_NAME/package.json" ]; then
          (
            cd "$TEMP_CLONE_DIR"
            for b in $(git branch -r 2>/dev/null | grep -v 'HEAD' | tr -d ' ' | sed 's/origin\///'); do
              git checkout "$b" >/dev/null 2>&1 || true
              if [ -f "package.json" ] || [ -f "$APP_NAME/package.json" ] || [ -f "app/$APP_NAME/package.json" ]; then
                break
              fi
            done
          )
        fi

        if [ -d "$TEMP_CLONE_DIR/app/$APP_NAME" ] && [ -f "$TEMP_CLONE_DIR/app/$APP_NAME/package.json" ]; then
          APP_SRC="$TEMP_CLONE_DIR/app/$APP_NAME"
        elif [ -d "$TEMP_CLONE_DIR/$APP_NAME" ] && [ -f "$TEMP_CLONE_DIR/$APP_NAME/package.json" ]; then
          APP_SRC="$TEMP_CLONE_DIR/$APP_NAME"
        elif [ ! -f "$APP_SRC/package.json" ]; then
          FOUND_PKG=$(find "$TEMP_CLONE_DIR" -name "package.json" 2>/dev/null | grep -E "/($APP_NAME|app)/package\.json$" | head -n 1 || true)
          if [ -z "$FOUND_PKG" ]; then
            FOUND_PKG=$(find "$TEMP_CLONE_DIR" -name "package.json" 2>/dev/null | head -n 1 || true)
          fi
          if [ -n "$FOUND_PKG" ]; then
            APP_SRC=$(dirname "$FOUND_PKG")
          fi
        fi
      else
        rm -rf "$TEMP_CLONE_DIR"
        TEMP_CLONE_DIR=""
        die "Could not clone from $REPO_URL and no local registry found at $LOCAL_REGISTRY/$APP_NAME"
      fi
    fi
  else
    die "No source available. Pass a git URL as the first argument or set registries.default.gitUrl in $CONFIG_FILE"
  fi

  [ -f "$APP_SRC/package.json" ] || die "No package.json found at $APP_SRC"
}

# Decide install target. System apps default to the system tree; override with
# INSTALL_TARGET_OVERRIDE=USER|SYSTEM.
resolve_target() {
  IS_SYSTEM_APP=$(APP_SRC="$APP_SRC" node -e "
    const fs = require('fs');
    const path = require('path');
    const pkg = JSON.parse(fs.readFileSync(path.join(process.env.APP_SRC, 'package.json'), 'utf8'));
    process.stdout.write(pkg.system === true ? 'yes' : 'no');
  ")

  case "${INSTALL_TARGET_OVERRIDE:-}" in
  USER)
    TARGET="user"
    ;;
  SYSTEM)
    TARGET="system"
    ;;
  "")
    [ "$IS_SYSTEM_APP" = "yes" ] && TARGET="system" || TARGET="user"
    ;;
  *)
    die "Invalid INSTALL_TARGET_OVERRIDE '$INSTALL_TARGET_OVERRIDE' (expected USER or SYSTEM)"
    ;;
  esac

  if [ "$TARGET" = "system" ]; then
    APP_DATA_DIR="$SYSTEM_APP_DATA_DIR"
    BIN_DIR="$SYSTEM_BIN_DIR"
    # Privileges are only needed for the system tree.
    if [ "$(id -u)" = "0" ]; then
      SUDO=""
    else
      SUDO="sudo"
    fi
  else
    # User-level installs never escalate.
    APP_DATA_DIR="$USER_APP_DATA_DIR"
    BIN_DIR="$USER_BIN_DIR"
    SUDO=""
  fi
}

# Build @walterjwhite/lib from a monorepo-style clone (repo root layout) if it
# is present and no bundled _deps copy exists.
prepare_lib() {
  LIB_STAGED=""
  if [ -d "$BOOTSTRAP_TMP/_deps/@walterjwhite/lib" ]; then
    LIB_STAGED="$BOOTSTRAP_TMP/_deps/@walterjwhite/lib"
    return
  fi

  LIB_SOURCE=""
  if [ -d "$(dirname "$APP_SRC")/../../lib" ] && [ -f "$(dirname "$APP_SRC")/../../lib/package.json" ]; then
    LIB_SOURCE="$(cd "$(dirname "$APP_SRC")/../.." && pwd)/lib"
  elif [ -f "$SCRIPT_DIR/lib/package.json" ]; then
    LIB_SOURCE="$SCRIPT_DIR/lib"
  fi

  [ -n "$LIB_SOURCE" ] || return 0

  log "Building workspace lib at: $LIB_SOURCE"
  if [ -f "$LIB_SOURCE/tsconfig.json" ] && [ -d "$LIB_SOURCE/src" ]; then
    (cd "$LIB_SOURCE" && npm install --no-workspaces && npm run build)
    [ -d "$LIB_SOURCE/dist" ] || die "Build failed - dist directory not created in $LIB_SOURCE"
  fi

  LIB_TMP=$(mktemp -d)
  chmod 755 "$LIB_TMP"
  cp "$LIB_SOURCE/package.json" "$LIB_TMP/"
  node -e "
    const fs = require('fs');
    const path = require('path');
    const pkgPath = path.join('$LIB_TMP', 'package.json');
    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));

    if (pkg.exports) {
      for (const key in pkg.exports) {
        if (pkg.exports[key].default) {
          pkg.exports[key].default = pkg.exports[key].default.replace(/^\.\/dist\//, './');
        }
        if (pkg.exports[key].types) {
          pkg.exports[key].types = pkg.exports[key].types.replace(/^\.\/dist\//, './');
        }
      }
    }

    if (pkg.main && pkg.main.startsWith('./dist/')) {
      pkg.main = pkg.main.replace(/^\.\/dist\//, './');
    }
    if (pkg.types && pkg.types.startsWith('./dist/')) {
      pkg.types = pkg.types.replace(/^\.\/dist\//, './');
    }

    fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2));
  "

  cp "$LIB_SOURCE/package-lock.json" "$LIB_TMP/" 2>/dev/null || true
  cp "$LIB_SOURCE/LICENSE" "$LIB_TMP/" 2>/dev/null || true
  cp "$LIB_SOURCE/README.md" "$LIB_TMP/" 2>/dev/null || true
  cp "$LIB_SOURCE/.app" "$LIB_TMP/" 2>/dev/null || true

  if [ -d "$LIB_SOURCE/dist" ]; then
    cp -r "$LIB_SOURCE/dist"/* "$LIB_TMP/"
  fi
  if [ -d "$LIB_SOURCE/setup" ]; then
    cp -r "$LIB_SOURCE/setup" "$LIB_TMP/"
  fi

  mkdir -p "$BOOTSTRAP_TMP/_deps/@walterjwhite"
  rm -rf "$BOOTSTRAP_TMP/_deps/@walterjwhite/lib"
  cp -rL "$LIB_TMP" "$BOOTSTRAP_TMP/_deps/@walterjwhite/lib"
  rm -rf "$LIB_TMP"
  LIB_STAGED="$BOOTSTRAP_TMP/_deps/@walterjwhite/lib"
}

# Stage the app in a user-owned directory and run npm there - never as root.
stage_install() {
  BOOTSTRAP_TMP="$USER_APP_DATA_DIR/tmp/bootstrap"
  rm -rf "$BOOTSTRAP_TMP"
  mkdir -p "$(dirname "$BOOTSTRAP_TMP")"
  cp -rL "$APP_SRC" "$BOOTSTRAP_TMP"

  prepare_lib

  log "Installing dependencies (as $(id -un))..."
  STAGE_DIR="$BOOTSTRAP_TMP" node -e "
    const fs = require('fs');
    const path = require('path');
    const pkgPath = path.join(process.env.STAGE_DIR, 'package.json');
    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
    const origDeps = pkg.dependencies || {};
    const filteredDeps = {};
    for (const [k, v] of Object.entries(origDeps)) {
      if (!k.startsWith('@walterjwhite/')) filteredDeps[k] = v;
    }
    pkg.dependencies = filteredDeps;
    fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2));
    try {
      require('child_process').execSync('npm install --omit=dev --no-save', { cwd: process.env.STAGE_DIR, stdio: 'inherit' });
    } finally {
      pkg.dependencies = origDeps;
      fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2));
    }
  "

  # Provision bundled @walterjwhite dependencies (stripped during npm install)
  if [ -n "$LIB_STAGED" ]; then
    mkdir -p "$BOOTSTRAP_TMP/node_modules/@walterjwhite"
    rm -rf "$BOOTSTRAP_TMP/node_modules/@walterjwhite/lib"
    cp -r "$LIB_STAGED" "$BOOTSTRAP_TMP/node_modules/@walterjwhite/lib"
  fi
}

publish_install() {
  INSTALL_DIR="$APP_DATA_DIR/install/$APP_NAME"

  log "Installing $APP_NAME to $INSTALL_DIR..."
  $SUDO rm -rf "$INSTALL_DIR"
  $SUDO mkdir -p "$INSTALL_DIR"
  $SUDO cp -r "$BOOTSTRAP_TMP"/. "$INSTALL_DIR"/
  $SUDO chmod -R u=rwX,go=rX "$INSTALL_DIR"
  $SUDO chmod 755 "$INSTALL_DIR/src/cli.ts"

  # Keep the local registry copy up to date (user-owned, no privileges needed).
  if [ -d "$LOCAL_REGISTRY/$APP_NAME" ]; then
    log "Updating local registry copy of $APP_NAME..."
    mkdir -p "$LOCAL_REGISTRY/$APP_NAME"
    cp -r "$BOOTSTRAP_TMP"/. "$LOCAL_REGISTRY/$APP_NAME"/
  fi

  log "Linking commands into $BIN_DIR..."
  $SUDO mkdir -p "$BIN_DIR"
  for f in "$INSTALL_DIR"/src/cmd/*.ts; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .ts)
    $SUDO rm -f "$BIN_DIR/$name"
    $SUDO ln -sfn "$INSTALL_DIR/src/cli.ts" "$BIN_DIR/$name"
  done

  if [ "$TARGET" = "system" ]; then
    if [ -d "$USER_APP_DATA_DIR/install/$APP_NAME" ]; then
      rm -rf "$USER_APP_DATA_DIR/install/$APP_NAME"
    fi
    for link in "$USER_BIN_DIR"/app-* "$USER_BIN_DIR"/software-center; do
      [ -L "$link" ] || continue
      target=$(readlink "$link" 2>/dev/null || true)
      case "$target" in
      *"/.data/app/install/$APP_NAME"* | *"/usr/local/share/app/install/$APP_NAME"*)
        rm -f "$link"
        ;;
      esac
      if [ ! -e "$link" ]; then
        rm -f "$link"
      fi
    done
  fi
}

create_config() {
  mkdir -p "$HOME/.config/walterjwhite/app"

  if [ ! -f "$CONFIG_FILE" ]; then
    log "Creating default configuration..."
    cat >"$CONFIG_FILE" <<EOF
# init utility configuration
artifactsRoot: $USER_APP_DATA_DIR/artifacts
registryRoot: $USER_APP_DATA_DIR/registry
installRoot: $USER_APP_DATA_DIR/install

registries:
  default:
    gitUrl: ${REPO_URL:-null}

appName: init
EOF
  fi
}

cleanup() {
  if [ -n "${TEMP_CLONE_DIR:-}" ] && [ -d "$TEMP_CLONE_DIR" ]; then
    rm -rf "$TEMP_CLONE_DIR"
  fi
  if [ -n "${BOOTSTRAP_TMP:-}" ] && [ -d "$BOOTSTRAP_TMP" ]; then
    rm -rf "$BOOTSTRAP_TMP"
  fi
}

main() {
  ensure_node
  ensure_git
  resolve_repo_url "$@"
  resolve_app_source
  resolve_target

  SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)

  trap cleanup EXIT INT TERM
  stage_install
  publish_install
  create_config

  # Older versions of this installer ran npm under sudo and could leave
  # root-owned files in user directories. Restore ownership if needed.
  if [ "$(id -u)" != "0" ]; then
    for homeDir in "$USER_APP_DATA_DIR" "$HOME/.config/walterjwhite" "$USER_BIN_DIR"; do
      if [ -d "$homeDir" ]; then
        $SUDO chown -R "$(id -un):" "$homeDir" 2>/dev/null || true
      fi
    done
  fi

  echo ""
  echo "Install complete!"
  echo ""
  echo "Commands available:"
  echo "  app-build <name>      Build an application"
  echo "  app-publish <name>    Publish an application"
  echo "  app-install <name>    Install an application"
  echo "  app-uninstall <name>  Uninstall an application"
  echo ""
  echo "Configuration: $CONFIG_FILE"
}

main "$@"
