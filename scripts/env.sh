# Incluido por los demás scripts: usa Xcode si está instalado aunque
# xcode-select apunte a Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* \
      && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
dev_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
