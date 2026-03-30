#!/usr/bin/env bash

echo -e "${BLUE}[*] nops Remote Deployment (nixos-anywhere)${NC}"
echo -e "${BLUE}[*] Generating ephemeral deployment flake...${NC}"
echo -e "${BLUE}[*] Preparing SOPS secrets for remote injection...${NC}"
echo -e "${BLUE}[*] Executing nixos-anywhere over SSH...${NC}"
sudo rm -rf "$TMP_DIR" "$EXTRA_FILES"
echo -e "${GREEN}[SUCCESS] Node deployed and rebooting! You can now SSH in and run nops-install.${NC}"
#!/usr/bin/env bash
echo "[DEPRECATED] This script is no longer used. Node deployment is now fully automated via the Controller node and deployments.json. See README.md for the new workflow."
exit 0
