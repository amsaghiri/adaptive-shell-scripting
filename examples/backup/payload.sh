# Adaptive backup: archive a project directory into a backup directory.
SRC="/data/projects"
DEST="/var/backups/projects"

mkdir -p "$DEST"
tar -czf "$DEST/projects-$(date +%Y%m%d-%H%M%S).tar.gz" -C "$SRC" .
echo "backup of $SRC written to $DEST"
