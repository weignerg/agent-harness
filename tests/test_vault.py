import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from harness.memory.vault_validator import validate_vault

class TestVaultStructure(unittest.TestCase):
    def test_repo_vault_validation(self):
        vault_path = ROOT / "vault"
        valid, errors = validate_vault(vault_path)
        self.assertTrue(valid, f"Vault validation failed: {errors}")

    def test_obsidian_config_registration(self):
        import json
        obs_cfg = Path.home() / ".config/obsidian/obsidian.json"
        if obs_cfg.exists():
            data = json.loads(obs_cfg.read_text())
            vaults = data.get("vaults", {})
            vault_paths = [v.get("path") for v in vaults.values() if isinstance(v, dict)]
            self.assertIn(str(Path.home() / "Vaults/home"), vault_paths, "Home vault path not registered in ~/.config/obsidian/obsidian.json")
            self.assertNotIn(str(ROOT / "vault"), vault_paths, "Repository template vault should not be registered in ~/.config/obsidian/obsidian.json")

if __name__ == "__main__":
    unittest.main()
