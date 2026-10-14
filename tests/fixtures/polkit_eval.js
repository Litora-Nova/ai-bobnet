// Test-only: evaluates a polkit .rules file against a synthetic (action, subject) pair.
//   node polkit_eval.js <rules-file> <action-id> <unit> <verb> <comma-separated groups of the subject>
// Prints the rule's result: "yes" | "no" | "auth_admin" | ... | "null" (NOT_HANDLED). Prints "ERROR: ..." on a rule exception.
const fs = require("fs");
const [file, actionId, unit, verb, groups] = process.argv.slice(2);
const rules = [];
const polkit = {
  addRule: (fn) => rules.push(fn),
  addAdminRule: () => {},
  log: () => {},
  Result: { YES: "yes", NO: "no", AUTH_SELF: "auth_self", AUTH_ADMIN: "auth_admin", AUTH_SELF_KEEP: "auth_self_keep",
            AUTH_ADMIN_KEEP: "auth_admin_keep", NOT_HANDLED: null, CANCEL: "cancel" },
};
const have = new Set((groups || "").split(",").filter(Boolean));
const subject = { user: "operator", isInGroup: (g) => have.has(g), local: true, active: true };
const action = { id: actionId, lookup: (k) => (k === "unit" ? unit : k === "verb" ? verb : undefined) };
try {
  new Function("polkit", fs.readFileSync(file, "utf8"))(polkit);
  let out = null;
  for (const r of rules) { const v = r(action, subject); if (v !== undefined && v !== null) { out = v; break; } }
  console.log(String(out));
} catch (e) { console.log("ERROR: " + e.message); }
