#!/bin/sh
# Classifier test: feeds each command through the gate with MACHINE_PRESSURE_DEBUG=1,
# which prints the class and skips the pressure probe.
HERE=$(cd "$(dirname "$0")" && pwd)
H=$HERE/../hooks/heavy-op-gate.sh
pass=0; fail=0

t() { # expected-class command [extra env assignment]
  got=$(printf '%s' "$2" | jq -Rs '{tool_input:{command:.}}' | env MACHINE_PRESSURE_DEBUG=1 ${3:-X_UNUSED=1} sh "$H")
  first=$(printf '%s' "$2" | head -1 | cut -c1-72)
  if [ "$got" = "class=$1" ]; then pass=$((pass+1)); echo "  ok    $1	<- $first"
  else fail=$((fail+1)); echo "  FAIL  want=$1 $got	<- $first"; fi
}

echo "== must pass: the word appears in text or data, not as the executed command =="
t none 'gh pr create --base main --title "x" --body "$(cat <<'"'"'BODY'"'"'
Run npm run test:e2e:affected before merge. playwright test is the gate.
BODY
)"'
t none 'gh pr create --body "Run npm install && npm run build first"'
t none 'ps -eo pid,command | grep -E "playwright|docker compose|jest" | head'
t none 'ps -eo pid,ppid,command | grep -Ei "playw|compo|jes[t]|node --watch" | grep -v grep'
t none 'docker ps -a --format "{{.Names}}"'
t none 'npx playwright test -c playwright.unit.config.ts playwright/unit/foo.spec.ts'
t none 'SOME_VAR=1 npx playwright test -c playwright.unit.config.ts'
t none 'npm run test:unit'
t none 'cd x && gh pr checks 281 --repo some-org/some-repo --watch'
t none 'echo "jest is great"; ls'
t none 'cat > /tmp/pr.md <<EOF
- e2e: npm run test:e2e:affected green
EOF
gh pr create --body-file /tmp/pr.md'
t none 'git log --oneline | grep -i "docker build"'

echo "== light: inspecting and freeing memory is never blocked =="
t none 'npm run e2e:down'
t none 'npm run e2e:status'
t none 'npm run e2e:reset'
t none 'docker compose down'
t none 'docker compose -f docker-compose.test.yml stop'
t none 'cd wt && docker-compose logs -f'

echo "== e2e: partial runs, stack boots and specs are heavy and capped =="
t e2e 'npm run test:e2e:affected'
t e2e 'E2E_PRUNE_ON_EXIT=1 ./scripts/e2e.sh --affected'
t e2e 'npm run e2e:up'
t e2e 'npx cypress run --spec cypress/e2e/a.cy.ts'
t e2e 'E2E_BASE_DIR=/x npm run e2e:up'
t e2e 'cd fe && npx playwright test playwright/e2e/foo.spec.ts'
t e2e 'npx playwright test'
t e2e 'npm run e2e:reset && npx playwright test playwright/e2e/foo.spec.ts'
t e2e 'nohup npx playwright test > /tmp/x.log 2>&1 < /dev/null &'

echo "== must still be caught =="
t e2e 'npm run test:e2e:full'
t e2e 'E2E_DOCKER=1 ./scripts/e2e.sh'
t e2e 'npm run test:e2e:docker'
t e2e './scripts/e2e.sh'
t docker 'docker compose -f docker-compose.test.yml up -d'
t docker 'docker buildx prune -f'
t docker 'docker build -t x .'
t install 'npm install --no-audit'
t install 'cd wt && npm ci'
t install 'npm i lodash'
t build 'npm run build'
t build 'npx next build'

echo "== tests: vitest and jest, through any launcher =="
t tests 'FEATURE_FLAG=false npm run vitest -- test/foo.test.ts'
t tests 'npx vitest run test/foo.test.ts'
t tests 'npm run test:affected'
t tests 'npm test'
t tests 'FEATURE_FLAG=false npm run jest -- test/foo.test.ts'
t tests 'npx jest --changedSince=origin/main'
t tests 'nohup env FEATURE_FLAG=false npm run jest -- test/x.test.ts > /tmp/x.log 2>&1 &'
t tests 'node node_modules/.bin/cross-env NODE_OPTIONS=x jest -w 3'
t tests 'jest test/foo.test.ts'
t none 'ps -eo pid,command | grep -E "vitest|playwright" | grep -v grep'

echo "== more launchers and false-match guards =="
t none 'cat jest.config.js'
t none 'git worktree add ../wt && grep -rn jest.config src'
t none 'echo "npm install" >> notes.txt'
t install 'pnpm install --frozen-lockfile'
t install 'bun install'
t build 'cargo build --release'
t build 'pnpm build'
t tests 'pytest -x tests/'
t tests 'cargo test'
t tests 'go test ./...'
t tests 'pnpm test -- --watch=false'
t docker 'docker-compose up --build'
t docker 'docker compose run --rm app npm test'
t none 'docker compose ps'
t none 'ls && pwd'

echo "== workspaces, runners and wrappers =="
t tests 'python -m pytest tests/'
t tests 'python3 -m pytest -x'
t build 'pnpm --filter web build'
t build 'npm run -w web build'
t build 'yarn workspace web build'
t tests 'pnpm --filter web test'
t tests 'npm run -w web test'
t tests 'yarn workspace web test'
t install 'sudo npm ci'
t install 'sudo -E npm install'
t install 'yarn'
t install 'npm install vitest'
t install 'pnpm add vitest'
t install 'yarn add -D jest'
t install 'bun add vitest'
t install 'pnpm add -D playwright'
t install 'sudo -u deploy npm ci'
t build 'sudo -u deploy -H pnpm build'
t none 'yarn dev'
t none 'npm view build version'
t build 'turbo run build'
t tests 'turbo run test'
t build 'make build'
t tests 'make test'
t build 'mvn clean package'
t tests 'mvn test'
t build 'gradle build'
t tests './gradlew test'
t docker 'docker run --rm -it ubuntu bash'
t none 'docker exec web ls'

echo "== an e2e script through a package manager, and package queries =="
t e2e 'npm run e2e'
t e2e 'pnpm e2e'
t e2e 'yarn e2e'
t e2e 'bun run e2e'
t e2e 'pnpm run e2e:headed'
t e2e 'cd web && npm run e2e -- --project=chromium'
t none 'npm run e2e:down'
t none 'npm ls jest'
t none 'npm view vitest version'
t none 'npm explain jest'
t none 'pnpm why vitest'
t none 'npm uninstall jest'
t none 'yarn info jest'

echo "== docker compose: only the subcommand decides =="
t none 'docker compose exec app npm run lint'
t none 'docker compose exec app rails db:migrate'
t none 'docker compose cp app:/x ./x'
t none 'docker compose -f a.yml -f b.yml exec app sh'
t docker 'docker compose -f a.yml -f b.yml up -d'
t docker 'docker compose --profile dev up'
t docker 'docker compose --dry-run build'
t docker 'docker-compose -p shop run --rm app npm test'

echo "== extra_heavy_patterns =="
t none 'npm run bigjob' MACHINE_PRESSURE_EXTRA_HEAVY_PATTERNS=
t heavy 'npm run bigjob' MACHINE_PRESSURE_EXTRA_HEAVY_PATTERNS=run.bigjob
t heavy 'ffmpeg -i a.mov b.mp4' MACHINE_PRESSURE_EXTRA_HEAVY_PATTERNS=^terraform,^ffmpeg
t none 'echo ffmpeg' MACHINE_PRESSURE_EXTRA_HEAVY_PATTERNS=^ffmpeg

echo
echo "classifier: passed=$pass failed=$fail"
[ "$fail" = 0 ]
