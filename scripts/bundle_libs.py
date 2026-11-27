"""Copy the Homebrew libraries an app links into its bundle, so it runs without Homebrew.

    uv run --no-project scripts/bundle_libs.py dist/Megane.app

Walks the executable's dependencies (and theirs) that live under Homebrew's prefix, copies
each into Contents/Frameworks under its install name, and rewrites every reference to
@rpath/<name>: the executable finds them through @executable_path/../Frameworks, the
libraries through @loader_path. Each library is re-signed ad hoc (install_name_tool breaks
the signature); sign the app itself afterwards.

Also writes Contents/Resources/ThirdParty/: one folder per Homebrew formula with its license
files, and THIRD_PARTY.md listing each formula's version, license, homepage and source
tarball, as the GPL and LGPL ask of anyone shipping these libraries.

Prints the highest minimum macOS version among the bundled libraries: the app can't run on
anything older.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PREFIX = "/opt/homebrew"


def run(*cmd: str) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def install_name(path: str) -> str | None:
    out = run("otool", "-D", path).splitlines()
    return out[1].strip() if len(out) > 1 else None


def dependencies(path: str) -> list[str]:
    own = install_name(path)
    deps = [line.strip().split(" (")[0] for line in run("otool", "-L", path).splitlines()[1:]]
    return [d for d in deps if d != own]


def rpaths(path: str) -> list[str]:
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset", run("otool", "-l", path))


def resolve(dep: str, referrer: str) -> str | None:
    """The real file behind a dependency, if it's a Homebrew library; None for system ones."""
    here = os.path.dirname(referrer)
    if dep.startswith(PREFIX):
        return os.path.realpath(dep)
    if dep.startswith("@loader_path/"):
        candidates = [os.path.join(here, dep.removeprefix("@loader_path/"))]
    elif dep.startswith("@rpath/"):
        name = dep.removeprefix("@rpath/")
        candidates = [os.path.join(rp.replace("@loader_path", here), name) for rp in rpaths(referrer)]
        candidates.append(os.path.join(here, name))
    else:
        return None
    for c in candidates:
        if os.path.exists(c) and os.path.realpath(c).startswith(PREFIX):
            return os.path.realpath(c)
    return None


def min_macos(path: str) -> tuple[int, ...]:
    m = re.search(r"minos (\d+(?:\.\d+)*)", run("otool", "-l", path))
    return tuple(int(x) for x in m.group(1).split(".")) if m else (0,)


def main(app: Path) -> None:
    exe = app / "Contents/MacOS" / app.stem
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(exist_ok=True)

    # Breadth-first over Homebrew dependencies; a library is named by its install name's
    # basename (libavcodec.63.dylib), the name the loader asks for.
    names: dict[str, str] = {}          # real path -> bundled name
    todo = [str(exe)]
    while todo:
        current = todo.pop()
        for dep in dependencies(current):
            real = resolve(dep, current)
            if real and real not in names:
                names[real] = os.path.basename(dep)
                todo.append(real)

    bundled: dict[str, Path] = {}       # real path -> copy in the bundle
    for real, name in names.items():
        target = frameworks / name
        shutil.copy2(real, target)
        target.chmod(0o755)
        bundled[real] = target

    def rewrite(binary: Path, original: str, rpath: str, set_id: bool) -> None:
        args = ["install_name_tool"]
        if set_id:
            args += ["-id", f"@rpath/{binary.name}"]
        for dep in dependencies(str(binary)):
            real = resolve(dep, original)
            if real in names:
                args += ["-change", dep, f"@rpath/{names[real]}"]
        for rp in rpaths(str(binary)):
            args += ["-delete_rpath", rp]
        args += ["-add_rpath", rpath, str(binary)]
        subprocess.run(args, check=True, capture_output=True)

    rewrite(exe, str(exe), "@executable_path/../Frameworks", set_id=False)
    for real, copy in bundled.items():
        rewrite(copy, real, "@loader_path", set_id=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(copy)], check=True, capture_output=True)

    # Nothing may still point into Homebrew.
    for binary in [exe, *bundled.values()]:
        leftover = [d for d in dependencies(str(binary)) if d.startswith(PREFIX)]
        if leftover:
            sys.exit(f"{binary.name} still links {leftover}")

    write_notices(app, list(names))
    oldest = max(min_macos(str(p)) for p in [exe, *bundled.values()])
    print(f"bundled {len(bundled)} libraries")
    print("minos " + ".".join(map(str, oldest)))


def write_notices(app: Path, reals: list[str]) -> None:
    # Cellar/<formula>/<version>/lib/... -> (formula, version, keg root)
    kegs = {}
    for real in reals:
        parts = Path(real).relative_to(f"{PREFIX}/Cellar").parts
        kegs[parts[0]] = (parts[1], Path(PREFIX, "Cellar", parts[0], parts[1]))
    info = {f["name"]: f for f in json.loads(run("brew", "info", "--json=v2", *sorted(kegs)))["formulae"]}

    out = app / "Contents/Resources/ThirdParty"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    lines = [
        "# Third-party libraries",
        "",
        "Megane.app includes these libraries, built by Homebrew, each under its own license.",
        "Their license files are in the folder of the same name next to this file; the source",
        "of each version is at the URL given.",
        "",
        "| library | version | license | source |",
        "|---|---|---|---|",
    ]
    for formula, (version, keg) in sorted(kegs.items()):
        meta = info.get(formula, {})
        dest = out / formula
        dest.mkdir()
        for f in keg.iterdir():
            if f.is_file() and re.match(r"(LICEN[CS]E|COPYING|NOTICE|AUTHORS)", f.name, re.I):
                shutil.copy2(f, dest / f.name)
        source = meta.get("urls", {}).get("stable", {}).get("url", meta.get("homepage", ""))
        if not any(dest.iterdir()):   # the keg ships no license file: say where to find it
            (dest / "LICENSE-NOTE.txt").write_text(
                f"{formula} {version} is licensed under {meta.get('license') or 'its own terms'}.\n"
                f"The license text is in its source: {source}\n")
        lines.append(f"| {formula} | {version} | {meta.get('license') or 'see folder'} | {source} |")
    (out / "THIRD_PARTY.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
