# Tailwind CSSのビルド
build-css:
	npx @tailwindcss/cli -i ./src/css/style.css -o ./src/css/tail.css

# 監視モードでのビルド (オプション)
watch-css:
	npx @tailwindcss/cli -i ./src/css/style.css -o ./src/css/tail.css --watch

zig-build-run:
	zig build run

dev: build-css zig-build-run

.PHONY: build-css watch-css