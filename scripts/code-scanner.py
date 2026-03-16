import argparse
import re
from pathlib import Path
from dataclasses import dataclass


@dataclass
class LuaFileStats:
    path: Path
    loc: int
    functions: int
    total_lines: int


def remove_block_comments(text: str) -> str:
    """
    Elimina comentarios de bloque Lua del tipo:
    --[[ ... ]]
    --[=[ ... ]=]
    --[==[ ... ]==]
    """
    pattern = r"--\[(=*)\[(.*?)\]\1\]"
    return re.sub(pattern, "", text, flags=re.DOTALL)


def count_code_lines(text: str) -> int:
    """
    Cuenta líneas de código aproximadas:
    - ignora líneas vacías
    - ignora líneas de comentario simple que empiezan con --
    - ignora comentarios de bloque
    """
    text = remove_block_comments(text)
    count = 0

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("--"):
            continue
        count += 1

    return count


def count_functions(text: str) -> int:
    """
    Cuenta declaraciones de funciones comunes en Lua.

    Cubre casos como:
    - function foo(...)
    - local function foo(...)
    - foo = function(...)
    - obj.foo = function(...)
    - obj:foo = function(...)
    - ["foo"] = function(...)
    """
    text = remove_block_comments(text)

    patterns = [
        r"\blocal\s+function\s+[A-Za-z_][A-Za-z0-9_]*\s*\(",
        r"\bfunction\s+[A-Za-z_][A-Za-z0-9_\.:\[\]\"']*\s*\(",
        r"\b[A-Za-z_][A-Za-z0-9_\.:\[\]\"']*\s*=\s*function\s*\(",
        r"\[\s*['\"][^'\"]+['\"]\s*\]\s*=\s*function\s*\(",
    ]

    total = 0
    for pattern in patterns:
        total += len(re.findall(pattern, text))

    return total


def analyze_file(file_path: Path) -> LuaFileStats | None:
    try:
        text = file_path.read_text(encoding="utf-8", errors="ignore")
    except Exception as ex:
        print(f"[WARN] No se pudo leer {file_path}: {ex}")
        return None

    return LuaFileStats(
        path=file_path,
        loc=count_code_lines(text),
        functions=count_functions(text),
        total_lines=len(text.splitlines()),
    )


def collect_lua_files(root: Path) -> list[Path]:
    return [p for p in root.rglob("*.lua") if p.is_file()]


def print_table(results: list[LuaFileStats], root: Path, top: int, metric: str) -> None:
    print(f"\nTop {top} archivos .lua por '{metric}':\n")

    header = f"{'#':<4} {'Archivo':<70} {'LOC':>8} {'Funcs':>8} {'Total':>8}"
    print(header)
    print("-" * len(header))

    for idx, item in enumerate(results[:top], start=1):
        try:
            relative = item.path.relative_to(root)
        except ValueError:
            relative = item.path

        file_name = str(relative)
        if len(file_name) > 70:
            file_name = "..." + file_name[-67:]

        print(f"{idx:<4} {file_name:<70} {item.loc:>8} {item.functions:>8} {item.total_lines:>8}")


def main():
    parser = argparse.ArgumentParser(
        description="Escanea archivos .lua y muestra un top configurable por líneas de código o funciones."
    )
    parser.add_argument(
        "root",
        nargs="?",
        default=".",
        help="Directorio raíz a escanear. Por defecto: directorio actual.",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=10,
        help="Cantidad de archivos a mostrar. Por defecto: 10.",
    )
    parser.add_argument(
        "--metric",
        choices=["loc", "functions"],
        default="loc",
        help="Métrica de ordenamiento: loc o functions. Por defecto: loc.",
    )
    parser.add_argument(
        "--min-loc",
        type=int,
        default=0,
        help="Filtra archivos con al menos esta cantidad de LOC.",
    )
    parser.add_argument(
        "--min-functions",
        type=int,
        default=0,
        help="Filtra archivos con al menos esta cantidad de funciones.",
    )

    args = parser.parse_args()
    root = Path(args.root).resolve()

    if not root.exists():
        raise SystemExit(f"El path no existe: {root}")

    lua_files = collect_lua_files(root)

    if not lua_files:
        print("No se encontraron archivos .lua")
        return

    results: list[LuaFileStats] = []
    for file_path in lua_files:
        stat = analyze_file(file_path)
        if stat is None:
            continue
        if stat.loc < args.min_loc:
            continue
        if stat.functions < args.min_functions:
            continue
        results.append(stat)

    if not results:
        print("No hubo resultados después de aplicar los filtros.")
        return

    if args.metric == "loc":
        results.sort(key=lambda x: (x.loc, x.functions, x.total_lines, str(x.path)), reverse=True)
    else:
        results.sort(key=lambda x: (x.functions, x.loc, x.total_lines, str(x.path)), reverse=True)

    print_table(results, root, args.top, args.metric)


if __name__ == "__main__":
    main()
