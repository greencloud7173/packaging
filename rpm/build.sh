#!/usr/bin/env bash
# Builds Fedora RPM packages from the project checkouts next to this
# repository. Each spec is generated from the project's Debian packaging, so
# the two stay in step and the Debian files remain the place to change what a
# package contains. Packages are built in dependency order, taken from the
# Build-Depends and Depends in their control files, and each one is built from
# its checkout's committed HEAD; the results go to out/rpm/. A native package,
# such as the cutefish-desktop metapackage, has no checkout and is built from
# its packaging alone.
#
#   rpm/build.sh                            # every package
#   rpm/build.sh cutefish-core settings     # just these
#   rpm/build.sh --install                  # every package, each installed
#                                           # before the ones that need it
#   rpm/build.sh --deps --skip x            # only their build dependencies
#   rpm/build.sh --snapshot                 # release named after the commit,
#                                           # e.g. 1.0-0.git20261020120000.1a2b3c4
#   rpm/build.sh --skip cutefish-webkit     # every package but this one
#
# The target is Fedora 44. Debian package names are translated through
# rpm/dependencies and licences come from rpm/licenses; a name Fedora does not
# have fails the build where it is needed, so the fix is a line in one of
# those two files.
set -Eeuo pipefail

PACKAGING="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$(dirname "$PACKAGING")"
OUT="$PACKAGING/out/rpm"

INSTALL=false
DEPS=false
SNAPSHOT=false
KEEP=false
SKIP=()
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --install) INSTALL=true ;;
    --deps) DEPS=true ;;
    --snapshot) SNAPSHOT=true ;;
    --keep) KEEP=true ;;
    --skip) SKIP+=("${2:?--skip needs a project}"); shift ;;
    *) echo "Error: unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

SUDO=(sudo)
if (( EUID == 0 )); then
  SUDO=()
fi

ALL=()
declare -A VERSIONS=()
while read -r project version; do
  [[ -z "$project" || "$project" == \#* ]] && continue
  ALL+=("$project")
  VERSIONS[$project]="$version"
done < "$PACKAGING/versions"

for name in "$@" ${SKIP[@]+"${SKIP[@]}"}; do
  [[ -n "${VERSIONS[$name]:-}" ]] || { echo "Error: $name is not in versions" >&2; exit 1; }
done

# Debian package name -> Fedora package name. A name that is not in the table
# is used as it is, which covers the Cutefish packages themselves.
declare -A FEDORA=()
while read -r from to; do
  [[ -z "$from" || "$from" == \#* ]] && continue
  FEDORA[$from]="$to"
done < "$PACKAGING/rpm/dependencies"

declare -A LICENSES=()
while read -r package licence; do
  [[ -z "$package" || "$package" == \#* ]] && continue
  LICENSES[$package]="$licence"
done < "$PACKAGING/rpm/licenses"

# Which project builds each binary package.
declare -A OWNER=()
for project in "${ALL[@]}"; do
  while read -r package; do
    OWNER[$package]="$project"
  done < <(awk '/^Package:/ { print $2 }' "$PACKAGING/debian/$project/debian/control")
done

# The other projects a project's control file names in its build or runtime
# dependencies.
dependencies() {
  local word
  awk '/^[A-Za-z-]+:/ { field = ($1 == "Build-Depends:" || $1 == "Build-Depends-Indep:" || $1 == "Depends:") }
       field { sub(/^[A-Za-z-]+:/, ""); gsub(/\([^)]*\)|\[[^]]*\]|<[^>]*>|[,|]/, " "); print }' \
    "$PACKAGING/debian/$1/debian/control" \
    | tr -s ' \t' '\n' | while read -r word; do
        [[ -n "$word" && -n "${OWNER[$word]:-}" && "${OWNER[$word]}" != "$1" ]] && echo "${OWNER[$word]}"
      done | sort -u
}

# Depth-first, so a project comes after everything it depends on; ties keep
# the order of the versions file.
ORDER=()
declare -A STATE=()
visit() {
  local project="$1" dependency
  [[ "${STATE[$project]:-}" == complete ]] && return
  if [[ "${STATE[$project]:-}" == visiting ]]; then
    echo "Error: dependency cycle through $project" >&2
    exit 1
  fi
  STATE[$project]=visiting
  for dependency in $(dependencies "$project"); do
    visit "$dependency"
  done
  STATE[$project]=complete
  ORDER+=("$project")
}
for project in "${ALL[@]}"; do
  visit "$project"
done

PROJECTS=()
for project in "${ORDER[@]}"; do
  [[ " ${SKIP[*]-} " == *" $project "* ]] && continue
  if (( $# == 0 )) || [[ " $* " == *" $project "* ]]; then
    PROJECTS+=("$project")
  fi
done

# The lines of the named control fields, continuations included.
control_field() {
  local file="$1" names=" $* " line name value
  local wanted=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Za-z][A-Za-z-]*):(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      wanted=0
      if [[ "$names" == *" $name "* ]]; then
        wanted=1
        printf '%s\n' "$value"
      fi
    elif (( wanted )) && [[ "$line" == " "* ]]; then
      printf '%s\n' "$line"
    else
      wanted=0
    fi
  done < "$file"
}

# The Fedora names of the packages the named control fields depend on, one per
# line. Version constraints are dropped, because Fedora's versions are its
# own, and so are the ${...:Depends} placeholders, which only Debian's build
# tools fill in.
control_packages() {
  local project="$1" name fedora
  shift
  while read -r name; do
    [[ -z "$name" ]] && continue
    # ${misc:Depends} and its kind: Debian's build tools fill these in.
    [[ "$name" == "\${"* ]] && continue
    name="${name%%:*}"
    # Fedora has no librust-*-dev packages; the crates come from crates.io.
    [[ "$name" == librust-* ]] && continue
    if [[ -n "${FEDORA[$name]:-}" ]]; then
      fedora="${FEDORA[$name]}"
      [[ "$fedora" == - ]] && continue
    else
      fedora="$name"
    fi
    echo "$fedora"
  done < <(control_field "$PACKAGING/debian/$project/debian/control" "$@" \
    | sed -e 's/([^)]*)//g' -e 's/\[[^]]*\]//g' -e 's/<[^>]*>//g' -e 's/[,|]/ /g' \
    | tr -s ' \t' '\n' | sed '/^$/d')
}

# CMake options that go beyond the common ones, from each project's rules.
declare -A CMAKE_EXTRA=(
  [cutefish-compositor]="-DCUTEFISH_ENABLE_XWAYLAND=ON"
  [cutefish-webkit]="-DPORT=Cutefish -DCMAKE_BUILD_TYPE=Release -GNinja"
)

# A project is native when its Debian source format says so, which is how the
# metapackages are told apart: they have no upstream checkout to build.
is_native() {
  grep -qs native "$PACKAGING/debian/$1/debian/source/format"
}

# How a project builds: its Debian rules decide between CMake, Cargo, and
# shipping files that are already in its checkout.
build_system() {
  local control="$PACKAGING/debian/$1/debian/control"
  if control_field "$control" Build-Depends | grep -qw cargo; then
    echo cargo
  elif control_field "$control" Build-Depends | grep -qw cmake; then
    echo cmake
  else
    echo files
  fi
}

# Fedora keeps unit files and the other systemd-managed files in /usr/lib on
# every architecture, but %{_libdir} is lib64 on the 64-bit ones, so what a
# project installs there would land where systemd never looks.
fix_system_dirs() {
  cat <<'EOF'
%if "%{_libdir}" != "%{_prefix}/lib"
for dir in systemd/system systemd/user tmpfiles.d sysusers.d; do
    if [ -d "%{buildroot}%{_libdir}/$dir" ]; then
        install -d "%{buildroot}%{_prefix}/lib/$dir"
        mv "%{buildroot}%{_libdir}/$dir/"* "%{buildroot}%{_prefix}/lib/$dir/"
        rmdir "%{buildroot}%{_libdir}/$dir"
    fi
done
%endif
EOF
}

write_spec() {
  local project="$1" source="$2" version="$3" release="$4"
  local control="$PACKAGING/debian/$project/debian/control"
  local spec="$OUT/SPECS/$source.spec"
  local system summary homepage architecture extra
  local -a description body build_requires runtime_requires recommends

  system="$(build_system "$project")"
  homepage="$(control_field "$control" Homepage | head -1 | sed 's/^ *//; s/ *$//')"
  architecture="$(control_field "$control" Architecture | head -1 | sed 's/^ *//; s/ *$//')"
  mapfile -t description < <(control_field "$control" Description | sed 's/^ *//')
  summary="${description[0]:-CutefishOS $project}"
  body=("${description[@]:1}")

  {
    echo "# Generated by rpm/build.sh from debian/$project/debian/control. Edit"
    echo "# that, not this file, and run the script again."
    echo

    # Debug information would make the artifacts and the disk the build needs
    # several times larger for no one to read them; the Debian packages leave
    # it out too. brp-compress renames the man pages after %install, which the
    # file list below could not follow, so it is off as well.
    echo "%global debug_package %{nil}"
    echo "%global __brp_compress %{nil}"
    echo "%global _missing_build_ids_terminate_build 0"
    if [[ "$project" == cutefish-webkit ]]; then
      # With debug information and LTO the build outgrows the runners' memory
      # and disk, as it does on Debian.
      echo "%global optflags %(echo %{optflags} | sed 's/-g//g')"
      echo "%global _lto_cflags %{nil}"
    fi
    echo

    echo "Name:           $source"
    echo "Version:        $version"
    echo "Release:        $release%{?dist}"
    echo "Summary:        $summary"
    echo "License:        ${LICENSES[$source]:-BSD-3-Clause}"
    echo "URL:            ${homepage:-https://github.com/cutefishos/$project}"
    if ! is_native "$project"; then
      echo "Source0:        %{name}-%{version}.tar.gz"
      if [[ "$project" == plymouth-theme ]]; then
        echo "Source1:        cutefish-plymouth-theme.cfg"
      fi
    fi
    [[ "$architecture" == all ]] && echo "BuildArch:      noarch"
    echo

    mapfile -t build_requires < <(control_packages "$project" Build-Depends Build-Depends-Indep | sort -u)
    case "$system" in
      # Fedora's %cmake generates Ninja files, which needs ninja on the
      # system whatever the project's own control file says.
      cmake) build_requires+=("gcc" "gcc-c++" "make" "ninja-build") ;;
      cargo) build_requires+=("gcc" "make") ;;
    esac
    printf '%s\n' ${build_requires[@]+"${build_requires[@]}"} | sed '/^$/d' | sort -u \
      | while read -r name; do echo "BuildRequires:  $name"; done
    echo

    mapfile -t runtime_requires < <(control_packages "$project" Depends | sort -u)
    mapfile -t recommends < <(control_packages "$project" Recommends | sort -u)
    printf '%s\n' ${runtime_requires[@]+"${runtime_requires[@]}"} | sed '/^$/d' \
      | while read -r name; do echo "Requires:       $name"; done
    printf '%s\n' ${recommends[@]+"${recommends[@]}"} | sed '/^$/d' \
      | while read -r name; do echo "Recommends:     $name"; done
    echo

    echo "%description"
    echo "$summary"
    if (( ${#body[@]} )); then
      echo
      printf '%s\n' "${body[@]}"
    fi
    echo

    echo "%prep"
    if is_native "$project"; then
      echo "# Nothing to unpack: a metapackage has no sources."
    else
      echo "%setup -q -n %{name}-%{version}"
    fi
    echo

    echo "%build"
    case "$project" in
      cutefish-toolkit)
        cat <<'EOF'
# The Skia build looks for GN in its own bin/; the package builds with the
# system's.
mkdir -p third_party/skia/bin
ln -sf %{_bindir}/gn third_party/skia/bin/gn
%cmake -DBUILD_TESTING=OFF
%cmake_build
EOF
        ;;
      cutefish-computer-use)
        cat <<'EOF'
# Debian builds from its librust-*-dev packages through the registry the
# project's .cargo/config.toml points at; Fedora has no such packages, so the
# crates come from crates.io.
rm -f .cargo/config.toml
locked=""
[ -f Cargo.lock ] && locked=--locked
cargo build --release $locked
EOF
        ;;
      *)
        if [[ "$system" == cmake ]]; then
          extra="${CMAKE_EXTRA[$project]:-}"
          if [[ "$project" == cutefish-webkit ]]; then
            echo "# WebKit turns its assertions off only under NDEBUG, which the"
            echo "# Release build type defines."
          fi
          echo "%cmake -DBUILD_TESTING=OFF${extra:+ $extra}"
          echo "%cmake_build"
        else
          echo "# The files are already in the checkout; there is nothing to build."
        fi
        ;;
    esac
    echo

    echo "%install"
    case "$project" in
      plymouth-theme)
        cat <<'EOF'
install -d %{buildroot}%{_datadir}/plymouth/themes
for theme in cutefish-logo cutefish-text; do
    [ -d "$theme" ] && cp -a "$theme" %{buildroot}%{_datadir}/plymouth/themes/
done
install -Dpm644 %{SOURCE1} \
    %{buildroot}%{_sysconfdir}/default/grub.d/cutefish-plymouth-theme.cfg
EOF
        ;;
      cutefish-computer-use)
        cat <<'EOF'
install -Dpm755 target/release/cutefish-computer-use \
    %{buildroot}%{_bindir}/cutefish-computer-use
EOF
        ;;
      *)
        if [[ "$system" == cmake ]]; then
          echo "%cmake_install"
          fix_system_dirs
        fi
        ;;
    esac
    if is_native "$project"; then
      echo "# A metapackage installs nothing."
    else
      cat <<'EOF'

# Everything that was installed, so that the packaging need not track it.
find %{buildroot} -type f -o -type l | sed "s|^%{buildroot}||" | sort > filelist
find %{buildroot} -mindepth 1 -type d -empty | sed "s|^%{buildroot}||" | sort >> filelist
EOF
    fi
    echo

    if is_native "$project"; then
      echo "%files"
    else
      echo "%files -f filelist"
    fi
    echo

    case "$project" in
      cutefish-core)
        cat <<'EOF'
%post
# x-session-manager, which the session starts, through Fedora's alternatives.
if command -v alternatives >/dev/null 2>&1; then
    alternatives --install /usr/bin/x-session-manager x-session-manager \
        /usr/bin/cutefish-session 60 || :
fi

# The shared Applications folder: administrators change it, others through
# cutefish-applications-folder. Fedora has no sudo group; wheel is its
# equivalent.
install -d -m 2775 /Applications
if getent group wheel >/dev/null; then
    chown root:wheel /Applications
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -m g:wheel:rwx -m d:g:wheel:rwx /Applications || :
    fi
fi

%preun
if [ $1 -eq 0 ] && command -v alternatives >/dev/null 2>&1; then
    alternatives --remove x-session-manager /usr/bin/cutefish-session || :
fi
EOF
        ;;
      cutefish-dm)
        cat <<'EOF'
%post
# The login screen's own user; it owns nothing but its home.
if ! getent passwd cutefish-greeter >/dev/null; then
    useradd --system --user-group --home-dir /var/lib/cutefish-greeter \
        --comment "Cutefish login screen" --shell /sbin/nologin \
        cutefish-greeter || :
fi
install -d -m 755 /var/lib/cutefish-dm

# The unit is left disabled: the user starts the display manager with
# systemctl, as on Debian, so that installing it does not take over tty1.
EOF
        ;;
      terminal)
        cat <<'EOF'
%post
# Lets x-terminal-emulator, which runs Terminal=true applications, open this
# terminal, through Fedora's alternatives.
if command -v alternatives >/dev/null 2>&1; then
    alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator \
        /usr/bin/cutefish-terminal 40 || :
fi

%preun
if [ $1 -eq 0 ] && command -v alternatives >/dev/null 2>&1; then
    alternatives --remove x-terminal-emulator /usr/bin/cutefish-terminal || :
fi
EOF
        ;;
      plymouth-theme)
        cat <<'EOF'
%post
if ! grep -q '^Theme=' /etc/plymouth/plymouthd.conf 2>/dev/null; then
    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        plymouth-set-default-theme cutefish-logo || :
    fi
fi
# Fedora rebuilds the initramfs with dracut, and only on a system with a
# kernel of its own: a container or a build root has none to rebuild for.
if [ -e "/boot/vmlinuz-$(uname -r)" ] && command -v dracut >/dev/null 2>&1; then
    dracut -f || :
fi

%preun
if [ $1 -eq 0 ] && command -v plymouth-set-default-theme >/dev/null 2>&1; then
    if [ "$(plymouth-set-default-theme 2>/dev/null)" = cutefish-logo ]; then
        plymouth-set-default-theme --reset || :
    fi
fi

%postun
if [ $1 -eq 0 ] && [ -e "/boot/vmlinuz-$(uname -r)" ] \
   && command -v dracut >/dev/null 2>&1; then
    dracut -f || :
fi
EOF
        ;;
    esac

    echo
    echo "%changelog"
    echo "* $(LC_ALL=C date -u '+%a %b %d %Y') Cutefish packaging <packaging@cutefish.org> - $version-$release"
    echo "- Fedora build, generated from the packaging in debian/$project."
  } > "$spec"
}

# The tarball rpmbuild unpacks: the checkout's committed HEAD, with the trees
# a project fetches rather than tracks, such as a pinned library's sources.
write_sources() {
  local project="$1" source="$2" upstream="$3"
  local src="$SOURCES/$project"
  local tarball="$OUT/SOURCES/$source-$upstream.tar"
  local vendor="$PACKAGING/debian/$project/vendor"
  local path
  local -a paths excludes

  rm -f "$tarball" "$tarball.gz"
  git -C "$src" archive --prefix="$source-$upstream/" -o "$tarball" HEAD
  if [[ -f "$vendor" ]]; then
    paths=()
    excludes=(--exclude=.git)
    while read -r path; do
      [[ -z "$path" || "$path" == \#* ]] && continue
      if [[ "$path" == !* ]]; then
        excludes+=("--exclude=${path#!}")
      elif [[ -d "$src/$path" ]]; then
        paths+=("$path")
      else
        echo "Error: $src/$path is missing; fetch it first" >&2
        exit 1
      fi
    done < "$vendor"
    tar -rf "$tarball" -C "$src" "${excludes[@]}" \
      --owner=0 --group=0 --numeric-owner \
      --transform="s|^|$source-$upstream/|" "${paths[@]}"
  fi
  gzip -9 -f "$tarball"
}

mkdir -p "$OUT/SOURCES" "$OUT/SPECS" "$OUT/BUILD" "$OUT/RPMS" "$OUT/SRPMS" "$OUT/logs"

echo "Build order: ${PROJECTS[*]}"

for project in "${PROJECTS[@]}"; do
  src="$SOURCES/$project"
  packaging="$PACKAGING/debian/$project/debian"
  changelog="$packaging/changelog"

  source="$(sed -n '1s/^\([^ ]*\) (.*/\1/p' "$changelog")"
  version="$(sed -n '1s/^[^ ]* (\([^)]*\)).*/\1/p' "$changelog")"
  upstream="${version%-*}"
  revision="${version##*-}"
  [[ -n "$source" && -n "$upstream" ]] || { echo "Error: cannot read $changelog" >&2; exit 1; }
  if [[ "$upstream" != "${VERSIONS[$project]}" ]]; then
    echo "Error: $project's changelog is at $version, versions says ${VERSIONS[$project]}" >&2
    exit 1
  fi

  release="$revision"
  if [[ "$SNAPSHOT" == true ]] && ! is_native "$project"; then
    stamp="$(TZ=UTC0 git -C "$src" log -1 --date=format-local:%Y%m%d%H%M%S --format=%cd HEAD)"
    release="0.git$stamp.$(git -C "$src" rev-parse --short=7 HEAD)"
  fi

  echo
  echo "==> [$project] $source $upstream-$release"

  if [[ "$INSTALL" == true || "$DEPS" == true ]] && ! is_native "$project"; then
    mapfile -t build_deps < <(control_packages "$project" Build-Depends Build-Depends-Indep | sort -u)
    if (( ${#build_deps[@]} )); then
      "${SUDO[@]}" dnf install -y --setopt=install_weak_deps=False "${build_deps[@]}"
    fi
  fi

  if is_native "$project"; then
    write_spec "$project" "$source" "$upstream" "$release"
  else
    [[ -d "$src" ]] || { echo "Error: $src is not a checkout" >&2; exit 1; }
    git -C "$src" rev-parse --verify --quiet HEAD >/dev/null \
      || { echo "Error: $src has no commit" >&2; exit 1; }
    write_sources "$project" "$source" "$upstream"
    write_spec "$project" "$source" "$upstream" "$release"
  fi

  if [[ "$project" == cutefish-plymouth-theme ]]; then
    cp "$packaging/cutefish-plymouth-theme.cfg" "$OUT/SOURCES/"
  fi

  log="$OUT/logs/$source.log"
  rpmbuild -bb --define "_topdir $OUT" "$OUT/SPECS/$source.spec" 2>&1 | tee "$log"

  if [[ "$INSTALL" == true ]]; then
    while read -r rpm; do
      "${SUDO[@]}" dnf install -y --nogpgcheck --setopt=install_weak_deps=False "$rpm"
    done < <(sed -n 's/^Wrote: \(.*\.rpm\)$/\1/p' "$log")
  fi

  [[ "$KEEP" == true ]] || rm -rf "$OUT/BUILD/"*

  echo "==> [$project] OK"
done

echo
echo "Packages are in $OUT/RPMS."
