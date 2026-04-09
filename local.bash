#!/bin/bash

mkdir build
cd build

if [[ $1 == "crescent" ]]; then
    module load CMake
fi

git clone https://github.com/KarypisLab/GKlib.git
make -C GKlib config cc=gcc
cd GKlib
make install
cd ..

if [[ $1 != "crescent" ]]; then
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
fi

# git clone git@github.com:ucns3d-team/UCNS3D.git
# git clone git@github.com:ucns3d-team/UCNS3D.git -b v4_gpu
# git clone git@github.com:ejb90/UCNS3D.git -b s421784
git clone git@github.com:ejb90/UCNS3D.git -b s421784_v4_gpu
cd UCNS3D/src
ln -sf ../bin/lib/tecplot/libtecio.a

if [[ $1 == "crescent" ]]; then
    module load intel
    # Switch bin/intel-compile/Makefile to mpiifort if on Crescent because the intel module
    # is ancient
    ln -sf ../../GKlib/build/Linux-x86_64/libGKlib.a
    ln -sf ../bin/lib/metis/libmetis.a
    ln -sf ../bin/lib/parmetis/libparmetis.a
    make -f ../bin/intel-compiler/Makefile clean all
else
    ln -sf ../../GKlib/build/Linux-x86_64/libGKlib.a
    ln -sf ../../METIS/build/libmetis/libmetis.a
    ln -sf ../../ParMETIS/build/Linux-x86_64/libparmetis/libparmetis.a
    make -f ../bin/gnu-compiler/Makefile clean all
fi