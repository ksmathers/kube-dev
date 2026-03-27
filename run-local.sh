. setting.sh



docker run -d --rm --platform=linux/amd64 -p7080:6080 -p23337:13337 -p9888:8888  ${APPNAME}:${VERSION}

echo "To access the application in the browser navigate to:"
echo "  NoVNC Shell:    http://localhost:7080/vnc.html?host=localhost&port=7080"
echo "  VS Code Server: http://localhost:23337"
echo "  JupyterLab:     http://localhost:9888"