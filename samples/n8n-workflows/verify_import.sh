#!/bin/sh
set -eu
n8n import:workflow --separate --input=/imports
mkdir -p /tmp/verified-workflows
n8n export:workflow --all --separate --output=/tmp/verified-workflows
node -e '
const fs = require("fs");
const path = "/tmp/verified-workflows";
const files = fs.readdirSync(path).filter(name => name.endsWith(".json"));
if (files.length !== 4) throw new Error(`Expected 4 workflows, got ${files.length}`);
let nodes = 0;
for (const file of files) {
  const workflow = JSON.parse(fs.readFileSync(`${path}/${file}`, "utf8"));
  if (workflow.active !== false) throw new Error("Imported workflow is active");
  for (const node of workflow.nodes) {
    if (node.credentials && Object.keys(node.credentials).length)
      throw new Error("Imported node has credential bindings");
    nodes++;
  }
}
if (nodes !== 18) throw new Error(`Expected 18 nodes, got ${nodes}`);
console.log(`PASS: imported ${files.length} inactive workflows with ${nodes} nodes and no credential bindings`);
'
