#!/usr/bin/env python3
import json
import re
import subprocess

REPORT_FILE = "report-CVE-2026-19553-426dad8ba33a733e675008fe53168a77.json"
OUTPUT_FILE = "python_libraries_comparison.json"
INDEX_URL = "https://pypi.python.org/simple"

# Load report
with open(REPORT_FILE, "r") as f:
    data = json.load(f)

# Extract python packages from sbom_info
packages = data.get("input", {}).get("image", {}).get("sbom_info", {}).get("packages", [])
python_pkgs = [p for p in packages if p.get("system") == "python"]

# Deduplicate by package name
unique_pkgs = {p["name"]: p for p in python_pkgs}.values()

results = []

for pkg in unique_pkgs:
    name = pkg["name"]
    installed_ver = pkg.get("version", "N/A")
    purl = pkg.get("purl", "")

    # Run pip index versions
    cmd = ["pip", "index", "versions", name, "--index-url", INDEX_URL]
    res = subprocess.run(cmd, capture_output=True, text=True)

    latest_ver = "N/A"
    if res.returncode == 0:
        # Match standard output format: package_name (X.Y.Z)
        match = re.search(r"\(([^)]+)\)", res.stdout)
        if match:
            latest_ver = match.group(1)

    print(f"Package: {name:<20} | Installed: {installed_ver:<12} | Latest PyPI: {latest_ver}")

    results.append({
        "name": name,
        "installed_version": installed_ver,
        "latest_version": latest_ver,
        "purl": purl,
        "raw_pip_output": res.stdout if res.returncode == 0 else res.stderr
    })

# Save results
with open(OUTPUT_FILE, "w") as f:
    json.dump(results, f, indent=2)

print(f"\nSaved comparison report to {OUTPUT_FILE}")
