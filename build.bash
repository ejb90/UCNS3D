#!/bin/bash

docker build . -t ucns3d -f Dockerfile --no-cache
# docker images
# docker ps -a
# docker run -it ucns3d:latest