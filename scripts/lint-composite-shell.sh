#!/usr/bin/env bash
#
# ShellCheck the shell embedded in this repository's composite actions.
#
# actionlint covers .github/workflows, but it explicitly does not check the
# steps of a composite action's metadata - "steps in Composite action's
# metadata is not checked at this point" - and it refuses action.yml as a
# command-line argument. Every line of shell in this repository lives in a
# */action.yml `run:` block, so without this the repo that ShellChecks the rest
# of the org never ShellChecks itself.
#
# Each `run:` block is written out with a shebang matching the step's declared
# shell, so ShellCheck knows the dialect, then checked at the same severity
# shell-lint applies to everyone else.
#
# Drop this and rely on actionlint alone once it checks composite steps.

set -euo pipefail

severity="${SEVERITY:-warning}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

status=0
checked=0

for meta in */action.yml; do
  [ -e "${meta}" ] || continue
  action="$(dirname "${meta}")"

  count="$(yq -r '[.runs.steps[]? | select(.run)] | length' "${meta}")"
  [ "${count}" -gt 0 ] || continue

  i=0
  while [ "${i}" -lt "${count}" ]; do
    name="$(yq -r "[.runs.steps[]? | select(.run)] | .[${i}].name // \"step ${i}\"" "${meta}")"
    shell="$(yq -r "[.runs.steps[]? | select(.run)] | .[${i}].shell // \"bash\"" "${meta}")"
    body="$(yq -r "[.runs.steps[]? | select(.run)] | .[${i}].run" "${meta}")"

    # A GitHub expression inside `run:` is not shell, and ShellCheck would
    # either choke on it or quietly mis-parse the line. Every step in this
    # repository passes values through `env:` instead, which is also what makes
    # the block safe from injection. Fail loudly if that ever stops being true
    # rather than skipping the block and reporting success.
    if printf '%s' "${body}" | grep -q '\${{'; then
      echo "::error::${meta} [${name}]: a GitHub expression appears inside run:. Pass it through env: instead, so the step is both lintable and injection-safe."
      status=1
      i=$((i + 1))
      continue
    fi

    out="${workdir}/${action}__${i}.sh"
    printf '#!/usr/bin/env %s\n%s\n' "${shell}" "${body}" > "${out}"

    if ! result="$(shellcheck -x --severity="${severity}" "${out}" 2>&1)"; then
      echo "::error::${meta} [${name}]: ShellCheck failed."
      # Rewrite the temp path back to something a reader can act on.
      printf '%s\n' "${result}" | sed "s|${out}|${meta} [${name}]|g"
      status=1
    fi

    checked=$((checked + 1))
    i=$((i + 1))
  done
done

if [ "${checked}" -eq 0 ]; then
  echo "::error::No composite run: steps were found. Either the layout changed or the extraction is broken; a silent pass here would be worse than a failure."
  exit 1
fi

echo "ShellChecked ${checked} composite run: step(s) at severity ${severity}."
exit "${status}"
