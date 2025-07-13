#!/bin/bash

mkdir build
cd build

git clone https://github.com/KarypisLab/GKlib.git
make -C GKlib config cc=gcc
cd GKlib
make install
cd ..

git clone https://github.com/KarypisLab/METIS.git
make -C METIS config cc=gcc
cd METIS
make install
cd ..

git clone https://github.com/KarypisLab/ParMETIS.git
make -C ParMETIS config cc=mpicc
cd ParMETIS
make install
cd ..

# git clone git@github.com:ucns3d-team/UCNS3D.git
git clone git@github.com:ejb90/UCNS3D.git -b s421784
cd UCNS3D/src
ln -sf ../../GKlib/build/Linux-x86_64/libGKlib.a
ln -sf ../../METIS/build/libmetis/libmetis.a
ln -sf ../../ParMETIS/build/Linux-x86_64/libparmetis/libparmetis.a
ln -sf ../bin/lib/tecplot/libtecio.a
make -f ../bin/gnu-compiler/Makefile clean all