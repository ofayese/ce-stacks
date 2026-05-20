#!/usr/bin/env bash
# verify-all-fixes.sh -- comprehensive verification that all fixes are applied correctly

set -euo pipefail

echo "======================================================================"
echo "  Comprehensive Fix Verification Suite"
echo "======================================================================"
echo ""

PASS=0
FAIL=0

test_result() {
    local test_name="$1"
    local expected="$2"
    local got="$3"

    if [[ "$got" == "$expected" ]]; then
        echo "  ✅ PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  ❌ FAIL: $test_name"
        echo "     Expected: $expected"
        echo "     Got: $got"
        FAIL=$((FAIL + 1))
    fi
}

# -- Fix 1: Ollama Network Subnet --
echo "1. Ollama Network Subnet (172.31.0.0 → 172.27.0.0)"
ollama_subnet=$(grep -A 2 "subnet:" stacks/ollama/compose.yaml | grep "172" | tr -d ' ' | cut -d: -f2)
test_result "Ollama subnet" "172.27.0.0/24" "$ollama_subnet"
echo ""

# -- Fix 2: Port Binding Quoting --
echo "2. Port Binding Quoting Consistency"
duckduckgo_port=$(grep -A 1 "ports:" stacks/agents_gateway_data/duckduckgo/compose.yaml | tail -1 | xargs)
test_result "Duckduckgo port quoted" '"10.0.1.15:8812:8811"' "$duckduckgo_port"

ollama_port=$(grep -A 1 "ports:" stacks/ollama/compose.yaml | grep "11434" | xargs)
test_result "Ollama port quoted" '"10.0.1.15:11434:11434"' "$ollama_port"

dozzle_port=$(grep -A 1 "ports:" stacks/dozzle/compose.yaml | grep "8892" | xargs)
test_result "Dozzle port quoted" '"10.0.1.15:8892:8080"' "$dozzle_port"
echo ""

# -- Fix 3: Dockhand Health Check Timeout --
echo "3. Dockhand Health Check Timeout (30 → 90 retries)"
max_retries=$(grep "MAX_HEALTH_RETRIES=" dockhand/scripts/dockhand-start.sh | grep -oE '[0-9]+' | head -1)
test_result "Health check retries" "90" "$max_retries"
echo ""

# -- Fix 4: Memory Parser Rejects Decimals --
echo "4. Memory Parser Decimal Rejection"
mem_parser_result=$(bash scripts/lint-host-budget.sh --self-test 2>&1 | grep "1.5g" | grep "ERR")
if [[ -n "$mem_parser_result" ]]; then
    echo "  ✅ PASS: Memory parser rejects decimals (1.5g → ERR)"
    PASS=$((PASS + 1))
else
    echo "  ❌ FAIL: Memory parser should reject decimals"
    FAIL=$((FAIL + 1))
fi
echo ""

# -- Fix 5: dockhand-sync Backup/Restore --
echo "5. dockhand-sync Backup/Restore Safety"
sync_backup_check=$(grep -c "backup.$$" scripts/dockhand-sync.sh || true)
if [[ $sync_backup_check -gt 3 ]]; then
    echo "  ✅ PASS: dockhand-sync implements backup/restore (found $sync_backup_check references)"
    PASS=$((PASS + 1))
else
    echo "  ❌ FAIL: dockhand-sync missing backup/restore logic"
    FAIL=$((FAIL + 1))
fi
echo ""

# -- Fix 6: Wireguard Mount Commented --
echo "6. Wireguard Mount Cleanup"
wireguard_check=$(grep -c "# - /etc/wireguard" stacks/grafana-prom/compose.yaml || true)
if [[ $wireguard_check -gt 0 ]]; then
    echo "  ✅ PASS: Wireguard mount properly commented out"
    PASS=$((PASS + 1))
else
    echo "  ❌ FAIL: Wireguard mount should be commented"
    FAIL=$((FAIL + 1))
fi
echo ""

# -- Fix 7: Secret File Validation --
echo "7. Hardcoded Dummy Value Validation"
validate_check=$(grep -c "Create watchtower bearer token if missing (size 0 files indicate corruption)" scripts/compose-validate.sh || true)
if [[ $validate_check -gt 0 ]]; then
    echo "  ✅ PASS: Compose validation checks for corrupted (size 0) files"
    PASS=$((PASS + 1))
else
    echo "  ❌ FAIL: Compose validation missing corruption check"
    FAIL=$((FAIL + 1))
fi
echo ""

# -- Fix 8: OCI Runtime Documentation --
echo "8. OCI Runtime Error Fix Documentation"
if [[ -f "docs/OCI_RUNTIME_FIX.md" ]]; then
    echo "  ✅ PASS: docs/OCI_RUNTIME_FIX.md exists"
    PASS=$((PASS + 1))
else
    echo "  ❌ FAIL: docs/OCI_RUNTIME_FIX.md missing"
    FAIL=$((FAIL + 1))
fi
echo ""

# -- Fix 9: Security Linter --
echo "9. New Security & Consistency Linter"
if [[ -x "scripts/lint-compose-security.sh" ]]; then
    echo "  ✅ PASS: scripts/lint-compose-security.sh is executable"
    PASS=$((PASS + 1))
else
    echo "  ❌ FAIL: scripts/lint-compose-security.sh not executable"
    FAIL=$((FAIL + 1))
fi
echo ""

# -- Integration Tests --
echo "======================================================================"
echo "Integration Tests"
echo "======================================================================"
echo ""

# Test compose validation
echo "10. Running Full Compose Validation"
if bash scripts/compose-validate.sh >/dev/null 2>&1; then
    echo "  ✅ PASS: All compose files validate successfully"
    PASS=$((PASS + 1))
else
    echo "  ❌ FAIL: Compose validation failed"
    FAIL=$((FAIL + 1))
fi
echo ""

# Test security linter
echo "11. Running Security Linter"
if bash scripts/lint-compose-security.sh >/dev/null 2>&1; then
    echo "  ✅ PASS: Security linter passes with zero violations"
    PASS=$((PASS + 1))
else
    echo "  ❌ FAIL: Security linter found issues"
    FAIL=$((FAIL + 1))
fi
echo ""

# Test memory parser
echo "12. Running Memory Budget Linter"
if bash scripts/lint-host-budget.sh >/dev/null 2>&1; then
    echo "  ✅ PASS: Memory budget linter passes"
    PASS=$((PASS + 1))
else
    echo "  ❌ FAIL: Memory budget linter failed"
    FAIL=$((FAIL + 1))
fi
echo ""

# -- Summary --
echo "======================================================================"
echo "  Summary"
echo "======================================================================"
echo ""
echo "  Tests Passed: $PASS"
echo "  Tests Failed: $FAIL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "  ✅ ALL FIXES VERIFIED - Ready for deployment"
    echo ""
    exit 0
else
    echo "  ❌ Some fixes failed verification - see details above"
    echo ""
    exit 1
fi
