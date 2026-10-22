// Node 本体だけでなく、ビルド時に使った共有ライブラリの版も確認する。
// バックポート（Brotli等）は版に現れないため、flake.lock のパッチも別途レビューする。
const minimum = {
	node: { 22: "22.23.4", 24: "24.22.1", 26: "26.12.1" }[
		process.versions.node.split(".")[0]
	],
	ares: "1.34.9",
	openssl: "3.5.9",
	sqlite: "3.53.4",
};

function atLeast(actual, required) {
	const match = /^(\d+)\.(\d+)\.(\d+)/.exec(actual ?? "");
	if (!match) return false;
	const parts = match.slice(1).map(Number);
	const target = required.split(".").map(Number);
	for (let i = 0; i < target.length; i++) {
		if (parts[i] !== target[i]) return parts[i] > target[i];
	}
	return true;
}

const versions = Object.fromEntries(
	Object.keys(minimum).map((name) => [name, process.versions[name]]),
);
console.log(JSON.stringify({ nodeSecurityVersions: versions }));
if (!minimum.node) {
	throw new Error(
		"Node.js 22 / 24 / 26 のセキュリティ修正版を使用してください",
	);
}
for (const [name, required] of Object.entries(minimum)) {
	if (!atLeast(versions[name], required)) {
		throw new Error(
			`${name} ${versions[name] ?? "unknown"} はセキュリティ修正版 ${required} 以上が必要です`,
		);
	}
}
