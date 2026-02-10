#!/usr/bin/env python3
import os
import re
import argparse
import difflib
from pathlib import Path

# CONFIGURATION
REPO_ROOT_NAME = "cluster-gitops"
CLUSTERS_REL_PATH = "clusters/environments.yaml"
BASES_PATTERN = re.compile(r'^bases:.*?(?=^\w+:|\Z)', re.MULTILINE | re.DOTALL)

def get_project_root():
    """Traverse up to find the cluster-gitops directory."""
    curr = Path(os.getcwd()).resolve()
    for parent in [curr] + list(curr.parents):
        if parent.name == REPO_ROOT_NAME:
            return parent
    raise RuntimeError(f"Could not find root directory: {REPO_ROOT_NAME}")

def process_helmfile(file_path, project_root, apply_changes):
    helmfile_dir = file_path.parent
    target_env_file = project_root / CLUSTERS_REL_PATH
    
    # Calculate relative path (e.g., ../../../clusters/environments.yaml)
    rel_link = os.path.relpath(target_env_file, helmfile_dir)
    base_snippet = f"bases:\n  - {rel_link}\n"

    with open(file_path, 'r') as f:
        old_content = f.read()

    # Replacement logic
    if "bases:" in old_content:
        new_content = BASES_PATTERN.sub(base_snippet, old_content)
    else:
        new_content = base_snippet + "\n" + old_content
    
    new_content = new_content.strip() + "\n"

    # Preview or Apply
    if old_content != new_content:
        print(f"\n--- Changes for {file_path.relative_to(project_root)} ---")
        diff = difflib.unified_diff(
            old_content.splitlines(), 
            new_content.splitlines(), 
            fromfile='original', tofile='proposed', lineterm=''
        )
        for line in diff:
            print(line)

        if apply_changes:
            with open(file_path, 'w') as f:
                f.write(new_content)
            print(f"✅ Applied changes to {file_path.name}")
    else:
        print(f"✔️ No changes needed for {file_path.relative_to(project_root)}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Inject bases into Helmfiles with dynamic paths.")
    parser.add_argument("--apply", action="store_true", help="Apply the changes to files. Default is dry-run.")
    args = parser.parse_args()

    try:
        root = get_project_root()
        if not args.apply:
            print("🔍 DRY-RUN MODE: No files will be modified. Use --apply to save changes.\n")
        
        for path in root.rglob("helmfile.yaml"):
            # Don't modify the shared environment file itself
            if CLUSTERS_REL_PATH not in str(path):
                process_helmfile(path, root, args.apply)
    except Exception as e:
        print(f"Error: {e}")

