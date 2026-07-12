#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_root="${BUILD_ROOT:-$script_dir/build}"
install_root="${INSTALL_ROOT:-$build_root/local}"
perf2_dir="${PERF2_DIR:-/home/ellis/Documents/cfd_msc/09_IRP/tests/perf2}"
smoke_root="${SMOKE_ROOT:-$build_root/smoke}"
mpi_ranks="${MPI_RANKS:-4}"
build_deps="${BUILD_DEPS:-auto}"

gklib_repo="${GKLIB_REPO:-https://github.com/KarypisLab/GKlib.git}"
metis_repo="${METIS_REPO:-https://github.com/KarypisLab/METIS.git}"
parmetis_repo="${PARMETIS_REPO:-https://github.com/KarypisLab/ParMETIS.git}"
ucns3d_repo="${UCNS3D_REPO:-git@github.com:ejb90/UCNS3D.git}"
ucns3d_branch="${UCNS3D_BRANCH:-s421784_v4_gpu}"

gklib_dir="$build_root/GKlib"
metis_dir="$build_root/METIS"
parmetis_dir="$build_root/ParMETIS"
ucns3d_dir="$build_root/UCNS3D"
src_dir="$ucns3d_dir/src"

gklib="$gklib_dir/build/Linux-x86_64/libGKlib.a"
metis="$metis_dir/build/libmetis/libmetis.a"
parmetis="$parmetis_dir/build/Linux-x86_64/libparmetis/libparmetis.a"
tecio="$ucns3d_dir/bin/lib/tecplot/libtecio.a"

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

clone_if_missing() {
    local repo="$1"
    local directory="$2"
    local branch="${3:-}"

    if [[ -d "$directory/.git" ]]; then
        printf 'Using existing checkout: %s\n' "$directory"
        return
    fi

    [[ ! -e "$directory" ]] || die "$directory exists but is not a Git checkout"

    if [[ -n "$branch" ]]; then
        git clone --branch "$branch" "$repo" "$directory"
    else
        git clone "$repo" "$directory"
    fi
}

build_dependency_libraries() {
    clone_if_missing "$gklib_repo" "$gklib_dir"
    clone_if_missing "$metis_repo" "$metis_dir"
    clone_if_missing "$parmetis_repo" "$parmetis_dir"

    printf 'Building GKlib\n'
    make -C "$gklib_dir" config cc=gcc prefix="$install_root"
    make -C "$gklib_dir" install

    printf 'Building METIS\n'
    make -C "$metis_dir" config cc=gcc prefix="$install_root" gklib_path="$install_root"
    cmake --build "$metis_dir/build" --target metis
    mkdir -p "$install_root/include" "$install_root/lib"
    cp "$metis_dir/build/xinclude/metis.h" "$install_root/include/"
    cp "$metis" "$install_root/lib/"

    printf 'Building ParMETIS\n'
    make -C "$parmetis_dir" config cc=mpicc prefix="$install_root" gklib_path="$install_root" metis_path="$install_root"
    cmake --build "$parmetis_dir/build/Linux-x86_64" --target parmetis
    cp "$parmetis_dir/include/parmetis.h" "$install_root/include/"
    cp "$parmetis" "$install_root/lib/"
}

copy_perf2_mesh() {
    local mesh_source="$perf2_dir/grid.msh"
    local mesh_target="$1/grid.msh"

    if head -n 1 "$mesh_source" | grep -q 'git-lfs.github.com/spec'; then
        local mesh_oid mesh_size mesh_object
        mesh_oid="$(awk '/^oid sha256:/ {sub("sha256:", "", $2); print $2}' "$mesh_source")"
        mesh_size="$(awk '/^size / {print $2}' "$mesh_source")"
        [[ -n "$mesh_oid" && -n "$mesh_size" ]] || die "Could not parse Git LFS pointer: $mesh_source"

        mesh_object="$(find /home/ellis/Documents/cfd_msc -type f \
            -path "*/.git/lfs/objects/${mesh_oid:0:2}/${mesh_oid:2:2}/$mesh_oid" \
            -print -quit 2>/dev/null || true)"
        [[ -n "$mesh_object" ]] || die "perf2 grid.msh is a Git LFS pointer, but object $mesh_oid is not cached locally"
        [[ "$(stat -c %s "$mesh_object")" == "$mesh_size" ]] || die "Cached mesh has the wrong size"
        [[ "$(sha256sum "$mesh_object" | awk '{print $1}')" == "$mesh_oid" ]] || die "Cached mesh checksum does not match the LFS pointer"
        cp "$mesh_object" "$mesh_target"
    else
        cp "$mesh_source" "$mesh_target"
    fi
}

run_smoke_test() {
    local smoke_dir mpi_status
    mkdir -p "$smoke_root"
    smoke_dir="$(mktemp -d "$smoke_root/perf2.XXXXXX")"
    ln -sfn "$smoke_dir" "$smoke_root/latest"

    cp "$perf2_dir/MULTISPECIES.DAT" "$smoke_dir/"
    cp "$perf2_dir/UCNS3D.DAT" "$smoke_dir/"
    copy_perf2_mesh "$smoke_dir"
    cp "$src_dir/ucns3d_p" "$smoke_dir/"

    cat > "$smoke_dir/MULTISPECIES.DAT" <<'EOF'
!------------MULTI-SPECIES DAT FILE-----!
!--------------UCNS3D-------------------!
3		!NUMBER OF SPECIES
1.66	1.4	1.4	!GAMMAS
0.0	1.0	0.0	!INFLOW VOLUME FRACTION
0.166	1.658	1.431	!INFLOW DENSITIES
0.0	0.0	0.0	!STIFFENED EOS PRESSURES
EOF

    cat > "$smoke_dir/407.nml" <<'EOF'
&bubble_case
  shock_position_x = -0.1
  left_pressure = 150000.0
  left_velocity = 114.49, 0.0, 0.0
  left_density = 0.166315789, 1.658, 1.431
  left_volume_fraction = 0.0, 1.0, 0.0
  right_pressure = 101325.0
  right_velocity = 0.0, 0.0, 0.0
  right_density = 0.166315789, 1.204, 1.431
  right_volume_fraction = 0.0, 1.0, 0.0
  bubble_count = 2
/

&bubble
  bubble_center = -0.05, 0.05, 0.0
  bubble_initial_radius = 0.025
  bubble_perturbation_amplitude = 0.0
  bubble_perturbation_modes = 0
  bubble_perturbation_phase = 0.0
  bubble_pressure = 101325.0
  bubble_velocity = 0.0, 0.0, 0.0
  bubble_density = 0.166315789, 1.204, 1.431
  bubble_volume_fraction = 0.95, 0.05, 0.0
/

&bubble
  bubble_center = 0.05, 0.05, 0.0
  bubble_initial_radius = 0.025
  bubble_perturbation_amplitude = 0.0
  bubble_perturbation_modes = 0
  bubble_perturbation_phase = 0.0
  bubble_pressure = 101325.0
  bubble_velocity = 0.0, 0.0, 0.0
  bubble_density = 0.166315789, 1.204, 1.431
  bubble_volume_fraction = 0.0, 0.05, 0.95
/
EOF

    awk 'NR == 8 {$2 = "407"} NR == 48 {$1 = "1.0"; $2 = "1"; $3 = "600"} {print}' \
        "$smoke_dir/UCNS3D.DAT" > "$smoke_dir/UCNS3D.DAT.tmp"
    mv "$smoke_dir/UCNS3D.DAT.tmp" "$smoke_dir/UCNS3D.DAT"

    printf 'Running one perf2 timestep with %s MPI ranks in %s\n' "$mpi_ranks" "$smoke_dir"
    set +e
    (
        cd "$smoke_dir"
        env OMP_NUM_THREADS=1 timeout 300s mpirun --oversubscribe -np "$mpi_ranks" "$smoke_dir/ucns3d_p"
    ) 2>&1 | tee "$smoke_dir/smoke.log"
    mpi_status="${PIPESTATUS[0]}"
    set -e

    [[ "$mpi_status" -eq 0 ]] || die "Smoke test MPI launch failed in $smoke_dir; see $smoke_dir/smoke.log"

    if [[ -f "$smoke_dir/history.txt" ]] && \
        grep -Eq '^[[:space:]]*[^[:space:]]+[[:space:]]+1[[:space:]]+time step size' "$smoke_dir/history.txt"; then
        printf 'Smoke test passed: timestep 1 completed successfully.\n'
        return
    fi

    grep -q 'ucns3d finished running' "$smoke_dir/smoke.log" || die "Smoke test did not finish cleanly; see $smoke_dir/smoke.log"
    printf 'Smoke test passed: UCNS3D finished cleanly.\n'
    printf 'Smoke test case kept at %s\n' "$smoke_dir"
}

for command in git make gcc mpicc mpif90 mpirun awk find grep head sha256sum stat mktemp timeout mkdir cp tee ln; do
    require_command "$command"
done

[[ "$build_deps" =~ ^(auto|yes|no)$ ]] || die "BUILD_DEPS must be auto, yes, or no"
[[ -d "$perf2_dir" ]] || die "perf2 input directory not found: $perf2_dir"

mkdir -p "$build_root"
clone_if_missing "$ucns3d_repo" "$ucns3d_dir" "$ucns3d_branch"
[[ -d "$src_dir" ]] || die "UCNS3D source directory not found after clone: $src_dir"

if [[ "$build_deps" == "yes" ]] || [[ "$build_deps" == "auto" && ( ! -f "$gklib" || ! -f "$metis" || ! -f "$parmetis" ) ]]; then
    build_dependency_libraries
elif [[ "$build_deps" == "auto" ]]; then
    printf 'Using existing dependency libraries under %s\n' "$build_root"
else
    printf 'Skipping dependency build because BUILD_DEPS=no\n'
fi

for library in "$gklib" "$metis" "$parmetis" "$tecio"; do
    [[ -f "$library" ]] || die "Required library not found: $library"
done

printf 'Building UCNS3D with dependencies from %s\n' "$build_root"
cd "$src_dir"
ln -sfn "$gklib" libGKlib.a
ln -sfn "$metis" libmetis.a
ln -sfn "$parmetis" libparmetis.a
ln -sfn "$tecio" libtecio.a

make -f ../bin/gnu-compiler/Makefile clean all \
    FFLAGS="$release_flags" \
    LIBS="-Wl,-Bstatic $tecio $parmetis $metis $gklib -Wl,-Bdynamic -lstdc++ -lpthread -lm -ldl -lc -lmpi"

[[ -x "$src_dir/ucns3d_p" ]] || die "Build completed without producing ucns3d_p"
printf 'Built %s\n' "$src_dir/ucns3d_p"

run_smoke_test
