#!/bin/bash
# generate-report.sh - Create a complete structure report

REPORT="ansible-structure-report.txt"

echo "Generating Ansible Structure Report..." > $REPORT
echo "=====================================" >> $REPORT
echo "Date: $(date)" >> $REPORT
echo "" >> $REPORT

# 1. Directory tree
echo "1. DIRECTORY TREE" >> $REPORT
echo "----------------" >> $REPORT
tree -L 4 >> $REPORT 2>/dev/null || find . -type d -not -path "*/\.*" | sort >> $REPORT
echo "" >> $REPORT

# 2. Task files overview
echo "2. TASK FILES OVERVIEW" >> $REPORT
echo "---------------------" >> $REPORT
echo "K3s Cluster Tasks:" >> $REPORT
ls -la roles/k3s_cluster/tasks/*.yaml 2>/dev/null >> $REPORT
echo "" >> $REPORT
echo "VM Tasks:" >> $REPORT
ls -la roles/k3s_cluster/tasks/vm/*.yaml 2>/dev/null >> $REPORT
echo "" >> $REPORT
echo "Helpers Tasks:" >> $REPORT
ls -la roles/helpers/tasks/*.yaml 2>/dev/null >> $REPORT
echo "" >> $REPORT

# 3. Critical files content
echo "3. CRITICAL FILE CONTENTS" >> $REPORT
echo "-----------------------" >> $REPORT

# configure_node.yaml (with iptables)
echo "=== configure_node.yaml ===" >> $REPORT
cat roles/k3s_cluster/tasks/configure_node.yaml 2>/dev/null >> $REPORT
echo -e "\n\n" >> $REPORT

# main.yaml
echo "=== main.yaml ===" >> $REPORT
cat roles/k3s_cluster/tasks/main.yaml 2>/dev/null >> $REPORT
echo -e "\n\n" >> $REPORT

# vm bootstrap
echo "=== vm/bootstrap.yaml ===" >> $REPORT
cat roles/k3s_cluster/tasks/vm/bootstrap.yaml 2>/dev/null >> $REPORT
echo -e "\n\n" >> $REPORT

# detect_runtime
echo "=== helpers/tasks/detect_runtime.yaml ===" >> $REPORT
cat roles/helpers/tasks/detect_runtime.yaml 2>/dev/null >> $REPORT
echo -e "\n\n" >> $REPORT

# 4. Check for LXC references
echo "4. LXC REFERENCES CHECK" >> $REPORT
echo "---------------------" >> $REPORT
echo "LXC references in VM tasks:" >> $REPORT
grep -r "lxc\|LXC" roles/k3s_cluster/tasks/vm/ 2>/dev/null >> $REPORT
echo "" >> $REPORT
echo "LXC references in configure_node.yaml:" >> $REPORT
grep -r "lxc\|LXC" roles/k3s_cluster/tasks/configure_node.yaml 2>/dev/null >> $REPORT
echo "" >> $REPORT

# 5. Runtime configuration
echo "5. RUNTIME CONFIGURATION" >> $REPORT
echo "----------------------" >> $REPORT
echo "VM variables:" >> $REPORT
cat roles/k3s_cluster/vars/vm.yaml 2>/dev/null >> $REPORT
echo "" >> $REPORT
echo "Container variables (if exists):" >> $REPORT
cat roles/k3s_cluster/vars/container.yaml 2>/dev/null >> $REPORT
echo "" >> $REPORT

echo "Report generated: $REPORT"
echo "Upload this file to share your structure"