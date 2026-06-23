#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_root="$(cd -- "$script_dir/.." && pwd)"
src_dir="$script_dir/src"
perf2_dir="${PERF2_DIR:-/home/ellis/Documents/cfd_msc/09_IRP/tests/perf2}"
mpi_ranks="${MPI_RANKS:-4}"

gklib_dir="$build_root/GKlib"
metis_dir="$build_root/METIS"
parmetis_dir="$build_root/ParMETIS"

gklib="$build_root/GKlib/build/Linux-x86_64/libGKlib.a"
metis="$build_root/METIS/build/libmetis/libmetis.a"
parmetis="$build_root/ParMETIS/build/Linux-x86_64/libparmetis/libparmetis.a"
tecio="$script_dir/bin/lib/tecplot/libtecio.a"

release_flags="-fdefault-real-8 -fdefault-double-8 -cpp -fbackslash -fopenmp"
release_flags+=" -ffree-line-length-none -finit-local-zero -fimplicit-none"
release_flags+=" -flto -fcray-pointer -O3 -march=native -Wno-lto-type-mismatch"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

for command in git make gcc mpicc mpif90 mpirun awk find sha256sum mktemp; do
    require_command "$command"
done

[[ -d "$src_dir" ]] || die "UCNS3D source directory not found: $src_dir"
[[ -d "$perf2_dir" ]] || die "perf2 input directory not found: $perf2_dir"

clone_if_missing() {
    local url="$1"
    local directory="$2"

    if [[ ! -d "$directory/.git" ]]; then
        [[ ! -e "$directory" ]] || die "$directory exists but is not a Git checkout"
        git clone "$url" "$directory"
    fi
}

# Preserve the original dependency workflow. Existing checkouts are reused;
# missing ones are cloned, and all three packages are built before UCNS3D.
clone_if_missing https://github.com/KarypisLab/GKlib.git "$gklib_dir"
clone_if_missing https://github.com/KarypisLab/METIS.git "$metis_dir"
clone_if_missing https://github.com/KarypisLab/ParMETIS.git "$parmetis_dir"

printf 'Building GKlib\n'
make -C "$gklib_dir" config cc=gcc
make -C "$gklib_dir" install

printf 'Building METIS\n'
make -C "$metis_dir" config cc=gcc
make -C "$metis_dir" install

printf 'Building ParMETIS with the current MPI compiler\n'
make -C "$parmetis_dir" config cc=mpicc
make -C "$parmetis_dir" install

for library in "$gklib" "$metis" "$parmetis" "$tecio"; do
    [[ -f "$library" ]] || die "Required library not found after build: $library"
done

printf 'Building UCNS3D with the libraries from %s\n' "$build_root"

cd "$src_dir"
ln -sfn "$gklib" libGKlib.a
ln -sfn "$metis" libmetis.a
ln -sfn "$parmetis" libparmetis.a
ln -sfn "$tecio" libtecio.a

# Fortran module files impose a strict compile order, so this must be serial.
make -f ../bin/gnu-compiler/Makefile clean all \
    FFLAGS="$release_flags" \
    LIBS="-Wl,-Bstatic $tecio $parmetis $metis $gklib -Wl,-Bdynamic -lstdc++ -lpthread -lm -ldl -lc -lmpi"

[[ -x "$src_dir/ucns3d_p" ]] || die "Build completed without producing ucns3d_p"
printf 'Built %s\n' "$src_dir/ucns3d_p"

smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/ucns3d-perf2-smoke.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT

cp "$perf2_dir/405.DAT" "$perf2_dir/MULTISPECIES.DAT" "$smoke_dir/"
cp "$perf2_dir/UCNS3D.DAT" "$smoke_dir/"
cp "$src_dir/ucns3d_p" "$smoke_dir/"

mesh_source="$perf2_dir/grid.msh"
if head -n 1 "$mesh_source" | grep -q 'git-lfs.github.com/spec'; then
    mesh_oid="$(awk '/^oid sha256:/ {sub("sha256:", "", $2); print $2}' "$mesh_source")"
    mesh_size="$(awk '/^size / {print $2}' "$mesh_source")"
    [[ -n "$mesh_oid" && -n "$mesh_size" ]] || die "Could not parse Git LFS pointer: $mesh_source"

    mesh_object="$(find /home/ellis/Documents/cfd_msc -type f \
        -path "*/.git/lfs/objects/${mesh_oid:0:2}/${mesh_oid:2:2}/$mesh_oid" \
        -print -quit 2>/dev/null || true)"
    [[ -n "$mesh_object" ]] || die "The perf2 mesh is a Git LFS pointer, but object $mesh_oid is not cached locally"
    [[ "$(stat -c %s "$mesh_object")" == "$mesh_size" ]] || die "Cached mesh has the wrong size"
    [[ "$(sha256sum "$mesh_object" | awk '{print $1}')" == "$mesh_oid" ]] || die "Cached mesh checksum does not match the LFS pointer"
    cp "$mesh_object" "$smoke_dir/grid.msh"
else
    cp "$mesh_source" "$smoke_dir/grid.msh"
fi

# Keep the original case unchanged. In the temporary copy, cap the run at
# one iteration and give it a generous simulation-time/wall-clock limit.
awk 'NR == 48 {$1 = "1.0"; $2 = "1"; $3 = "600"} {print}' \
    "$smoke_dir/UCNS3D.DAT" > "$smoke_dir/UCNS3D.DAT.tmp"
mv "$smoke_dir/UCNS3D.DAT.tmp" "$smoke_dir/UCNS3D.DAT"

printf 'Running one perf2 timestep with %s MPI ranks in %s\n' "$mpi_ranks" "$smoke_dir"
(
    cd "$smoke_dir"
    OMP_NUM_THREADS=1 timeout 120s mpirun --oversubscribe -np "$mpi_ranks" ./ucns3d_p
)

grep -Eq '^[[:space:]]*[^[:space:]]+[[:space:]]+1[[:space:]]+time step size' \
    "$smoke_dir/history.txt" || die "Smoke test did not complete timestep 1"

printf 'Smoke test passed: timestep 1 completed successfully.\n'
