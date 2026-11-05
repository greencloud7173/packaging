# packaging

Distribution packaging for the Cutefish desktop. The project repositories carry
no packaging of their own; it all lives here.

- `versions` lists each project's upstream version.
- `debian/<project>/debian/` is the `debian/` directory of that project's
  Debian source package.
- `rpm/` generates Fedora RPM packages from those Debian files.
- `arch/` will hold the Arch Linux PKGBUILDs.
- `iso/` is the live-build configuration of the Debian 13 live ISO.

## Debian

Check out the projects next to this repository, under their repository names:

```
cutefish-framework/
cutefish-core/
...
packaging/
```

Install the build tools, then build:

```shell
sudo apt install devscripts equivs --no-install-recommends
debian/build.sh --install               # every package, in dependency order
debian/build.sh cutefish-core settings  # just these
```

Packages are built in the order of the Build-Depends and Depends in their
control files. With `--install`, each package's build dependencies are
installed first and the package itself afterwards, so the next one can build
against it; without it, those must already be installed.

Each package is built from its checkout's committed HEAD, as a
`3.0 (quilt)` source package with a `.orig.tar.xz` exported by `git archive`.
A `debian/<project>/vendor` file names untracked trees of the checkout that go
into that tarball as well, such as the Skia sources cutefish-toolkit's
`scripts/fetch-skia.sh` fetches; a line starting with `!` leaves a path out.
Source and binary packages land in `out/debian/`. With `--snapshot`, each
package is versioned after its checkout's commit, such as
`1.0~git20261020120000.1a2b3c4-1`. The `~` puts snapshots before the release
in `versions`, so it should name the next release, not the last one.

`debian/publish.sh trixie-nightly repo/` lays those packages out as the
`trixie-nightly` suite of an APT repository under `repo/`; `--sign` signs it
with the default GnuPG key.

## APT repository

CI builds snapshots of every package each night and publishes them;
cutefish-webkit, which takes hours to build, is rebuilt only when its commit or
its packaging changes:

```
sudo curl -fsSLo /etc/apt/keyrings/cutefish.asc https://download.cutefish.org/debian/cutefish.asc
echo "deb [signed-by=/etc/apt/keyrings/cutefish.asc] https://download.cutefish.org/debian trixie-nightly main" \
  | sudo tee /etc/apt/sources.list.d/cutefish.list
sudo apt update
sudo apt install cutefish-desktop
```

## Fedora

Fedora 44 packages are generated from the Debian packaging by `rpm/build.sh`,
so there is nothing to write twice: `debian/<project>/debian/control` supplies
the dependencies, the summary and the description of the spec, and
`rpm/dependencies` and `rpm/licenses` translate the package names and hold the
licences Fedora does not take from `debian/copyright`.

Check out the projects as for Debian, then build, from the directory that
holds them all, on Fedora itself or in its container:

```shell
podman run --rm -it -v "$PWD:/work" -w /work fedora:44
dnf install -y ca-certificates git gn gzip redhat-rpm-config rpm-build tar
git config --global --add safe.directory '*'
packaging/rpm/build.sh --install                 # every package, in order
packaging/rpm/build.sh --deps cutefish-webkit    # just its build deps
packaging/rpm/build.sh --snapshot --skip cutefish-webkit
```

`--install` installs each package's build dependencies and then the package
itself, because Cutefish's own packages are not in Fedora's repositories;
`--deps` installs only the build dependencies. Packages land in `out/rpm/RPMS`
and the spec each was built from stays in `out/rpm/SPECS`, with the rpmbuild
output in `out/rpm/logs`. `--snapshot` names the release after the checkout's
commit, such as `0.git20261020120000.1a2b3c4`, since RPM versions may not carry
the `~` Debian uses for the same thing.

CI builds the packages for amd64 and arm64 inside `fedora:44` and uploads them
as the `rpm-amd64` and `rpm-arm64` artifacts of the `Build RPM packages`
workflow, cutefish-webkit as `webkit-rpm-<arch>`; a last job installs them on a
clean Fedora, which is what catches a dependency Fedora does not have. Nothing
is published and nothing is signed, so downloading an artifact is the way to
get packages, and `dnf install --nogpgcheck ./<file>.rpm` the way to install
them.

The spec differs from the Debian packaging where Fedora does:

- unit files, tmpfiles and sysusers move from `/usr/lib64` to `/usr/lib`, where
  systemd looks on every architecture;
- `update-alternatives` is Fedora's `alternatives`, and the `sudo` group is
  `wheel`;
- `update-initramfs` is `dracut -f`, run only where the system has the kernel
  it would rebuild for;
- no `-debuginfo` subpackages are produced, and the file lists are taken from
  what `%install` left behind rather than written by hand.

## ISO

The ISO installs `cutefish-desktop` from download.cutefish.org. CI builds it for
amd64 and arm64 after each package publish; to build it locally for the
machine's architecture, as root:

```shell
iso/build.sh
```

## Releasing a version

Change the project's line in `versions` and add a matching entry to its
`debian/changelog` with `dch`.

## License

Each package's licence is in its `debian/copyright`.
