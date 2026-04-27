. setting.sh

LCUSER=$(echo "$USER" | tr '[:upper:]' '[:lower:]')
mkdir -p "dev-home-${LCUSER}"
docker run -d --rm --platform=linux/amd64 -p7080:6080 \
  -v "dev-home-${LCUSER}:/home/dev" \
  ${APPNAME}:${VERSION}

echo "To access the application in the browser navigate to:"
echo "  NoVNC Shell: http://localhost:7080/vnc.html?host=localhost&port=7080"