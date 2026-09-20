#!/bin/sh
#
# Managed build settings must have exactly one source of truth: Config/*.xcconfig.
#
# Run from the repository root, after `xcodegen generate`. Three invariants:
#
#   1. project.yml is not a second source. It does not declare a managed setting
#      by name, it does not use the XcodeGen key that establishes one under a
#      different name, and it binds every supported build configuration to that
#      configuration's own xcconfig.
#   2. Config/*.xcconfig reduces to exactly one distinct literal value per
#      managed setting.
#   3. Every supported build configuration resolves exactly those values.
#
# ci.yml and guard-selftest.yml both run this file. The self-test breaks a
# throwaway copy on purpose and asserts that this script rejects it; a copy of
# the guard kept inside the self-test would prove nothing about the guard that CI
# actually runs.

set -eu

managed_settings='IPHONEOS_DEPLOYMENT_TARGET SWIFT_VERSION SWIFT_STRICT_CONCURRENCY'
managed_configurations='Debug Release'

temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
guard_tmp=$(mktemp -d "$temp_root/managed-build-settings.XXXXXX")
trap 'rm -rf "$guard_tmp"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# First invariant: project.yml must not be a second source for a managed
# setting, and must not rebind a configuration to another configuration's
# xcconfig.
#
# Psych inspects YAML mapping keys, so comments do not count while quoted keys,
# flow mappings and duplicate mapping keys are still seen.
# ---------------------------------------------------------------------------
if ! command -v ruby >/dev/null 2>&1; then
  echo "::error::ruby is unavailable; project.yml cannot be checked safely."
  exit 1
fi

project_hits="$guard_tmp/project-yml-hits.txt"
config_bindings="$guard_tmp/project-yml-config-bindings.txt"

if ! GUARD_HITS="$project_hits" \
     GUARD_BINDINGS="$config_bindings" \
     GUARD_CONFIGURATIONS="$managed_configurations" \
     ruby <<'RUBY'
require "psych"
require "date"

hits_path = ENV.fetch("GUARD_HITS")
bindings_path = ENV.fetch("GUARD_BINDINGS")
configurations = ENV.fetch("GUARD_CONFIGURATIONS").split

managed = %w[
  IPHONEOS_DEPLOYMENT_TARGET
  SWIFT_VERSION
  SWIFT_STRICT_CONCURRENCY
].freeze

# XcodeGen keys that set one of the managed settings without naming it.
# `deploymentTarget:` is the one that matters here: on an iOS target XcodeGen
# writes it into IPHONEOS_DEPLOYMENT_TARGET, so project.yml could hold a second
# source carrying the *same* value while every name- and value-based check below
# stayed green. Matching on the key name is deliberately fail-closed — this file
# describes project structure, and none of these names has a legitimate use in
# it.
semantic = %w[
  deploymentTarget
].freeze

forbidden = (managed + semantic).freeze

source = File.read("project.yml")
stream = Psych.parse_stream(source, filename: "project.yml")
hits = []

visit_yaml = nil
visit_yaml = lambda do |node|
  if node.is_a?(Psych::Nodes::Mapping)
    node.children.each_slice(2) do |key_node, value_node|
      if key_node.is_a?(Psych::Nodes::Scalar)
        name = key_node.value
        line = key_node.start_line + 1

        if semantic.include?(name)
          hits << "project.yml:#{line}: #{name} (XcodeGen writes this into IPHONEOS_DEPLOYMENT_TARGET)"
        elsif managed.include?(name)
          hits << "project.yml:#{line}: #{name}"
        end
      end

      visit_yaml.call(value_node)
    end
  # Scalar and Alias never initialise @children, so the reader returns nil for
  # them; only containers can be descended into. respond_to? is not enough —
  # every node class responds to :children and would then crash.
  elsif node.children
    node.children.each { |child| visit_yaml.call(child) }
  end
end
visit_yaml.call(stream)

document = Psych.safe_load(source, aliases: true, permitted_classes: [Date, Time])

config_files = []
declared_configs = []

visit_value = nil
visit_value = lambda do |value, path|
  case value
  when Hash
    value.each do |key, child|
      key_text = key.to_s
      child_path = "#{path}.#{key_text}"

      # The resolved object is what XcodeGen reads. Walking it alongside the AST
      # closes the exotic case where an alias is used as a mapping key: the AST
      # sees an Alias node and cannot name it, while the resolved key is the
      # scalar it points at.
      if hits.empty? && forbidden.include?(key_text)
        hits << "project.yml resolved path #{child_path}"
      end

      config_files << [child_path, child] if key_text == "configFiles"

      # Only the project-level `configs:` declares build configurations; a
      # `settings.configs:` further down only overrides settings for a
      # configuration that already exists.
      declared_configs << child if child_path == "$.configs" && child.is_a?(Hash)

      visit_value.call(child, child_path)
    end
  when Array
    value.each_with_index do |child, index|
      visit_value.call(child, "#{path}[#{index}]")
    end
  end
end
visit_value.call(document, "$")

# The binding, not the resolved value, is what makes Config/*.xcconfig
# authoritative. A value comparison cannot stand in for it: Release bound to
# Debug.xcconfig still resolves every managed setting to exactly the same value,
# because both files include Common.xcconfig.
problems = []

if config_files.empty?
  problems << "project.yml binds no build configuration to a Config/*.xcconfig file."
else
  config_files.each do |path, mapping|
    unless mapping.is_a?(Hash)
      problems << "#{path} is not a mapping of configuration name to xcconfig path."
      next
    end

    by_name = {}
    mapping.each { |key, target| by_name[key.to_s] = target }

    (by_name.keys - configurations).sort.each do |extra|
      problems << "#{path}.#{extra} binds a configuration this guard does not verify; add it to the guard's supported configurations, or drop the binding."
    end

    configurations.each do |name|
      expected = "Config/#{name}.xcconfig"
      actual = by_name.key?(name) ? by_name[name].to_s : nil

      if actual.nil?
        problems << "#{path} has no #{name} entry; #{name} would take its settings from Xcode's defaults instead of #{expected}."
      elsif actual != expected
        problems << "#{path}.#{name} is '#{actual}'; it must be '#{expected}'."
      elsif !File.file?(actual)
        problems << "#{path}.#{name} is '#{actual}', which does not exist; a binding to a missing file is not a binding."
      end
    end
  end
end

# A configuration nobody binds is a configuration nobody checks: Xcode resolves
# the managed settings for it from its own defaults, which is the state this
# whole invariant exists to forbid. Checking only the bindings would let a
# `Staging:` appear under `configs:` and go unverified — the same hole, one key
# over.
declared_configs.each do |mapping|
  (mapping.keys.map(&:to_s) - configurations).sort.each do |extra|
    problems << "project.yml declares the build configuration '#{extra}', which the guard does not verify; add it to the guard's supported configurations and give it a Config/#{extra}.xcconfig, or drop it."
  end
end

write = lambda do |path, lines|
  File.write(path, lines.empty? ? "" : "#{lines.uniq.join("\n")}\n")
end

write.call(hits_path, hits)
write.call(bindings_path, problems)
RUBY
then
  echo "::error::project.yml could not be parsed while checking managed settings."
  exit 1
fi

# Exit status alone is not a verdict. The program writes both files on every
# path it completes, but a `ruby` that exited 0 without reaching those writes
# would leave them absent — and `[ -s ]` on a file that was never created is
# false, so "no violations" and "never ran" would look exactly alike.
for verdict in "$project_hits" "$config_bindings"; do
  if [ ! -f "$verdict" ]; then
    echo "::error::the project.yml check produced no verdict: $verdict was never written, so the first invariant did not run."
    exit 1
  fi
done

if [ -s "$project_hits" ]; then
  echo "::error::project.yml must not declare a managed build setting, by name or through an XcodeGen key that sets one:"
  sed 's/^/  /' "$project_hits"
  echo "Config/*.xcconfig is their only source of truth."
  exit 1
fi

if [ -s "$config_bindings" ]; then
  echo "::error::project.yml does not bind every supported build configuration to its own Config/<configuration>.xcconfig:"
  sed 's/^/  /' "$config_bindings"
  echo "A matching resolved value is not a substitute: a Release binding pointed at Debug.xcconfig still resolves the same managed values, because both include Common.xcconfig."
  exit 1
fi

# ---------------------------------------------------------------------------
# Second invariant: every managed setting must have exactly one distinct,
# literal value across Config/*.xcconfig.
# ---------------------------------------------------------------------------
set -- Config/*.xcconfig
if [ "$1" = 'Config/*.xcconfig' ] || [ ! -f "$1" ]; then
  echo "::error::No Config/*.xcconfig files were found."
  exit 1
fi

config_records="$guard_tmp/config-records.tsv"
if ! awk '
  BEGIN {
    managed["IPHONEOS_DEPLOYMENT_TARGET"] = 1
    managed["SWIFT_VERSION"] = 1
    managed["SWIFT_STRICT_CONCURRENCY"] = 1
  }

  function strip_comments(text,    output, line_comment, block_comment) {
    output = ""

    while (length(text) > 0) {
      if (in_block_comment) {
        block_comment = index(text, "*/")
        if (block_comment == 0) {
          return output
        }

        text = substr(text, block_comment + 2)
        in_block_comment = 0
        continue
      }

      line_comment = index(text, "//")
      block_comment = index(text, "/*")

      if (line_comment > 0 &&
          (block_comment == 0 || line_comment < block_comment)) {
        output = output substr(text, 1, line_comment - 1)
        return output
      }

      if (block_comment > 0) {
        output = output substr(text, 1, block_comment - 1)
        text = substr(text, block_comment + 2)
        in_block_comment = 1
        block_start_file = FILENAME
        block_start_line = FNR
      } else {
        output = output text
        return output
      }
    }

    return output
  }

  FNR == 1 && NR != 1 && in_block_comment {
    printf "::error file=%s,line=%d::Unterminated block comment in xcconfig.\n",
           block_start_file, block_start_line
    bad = 1
    in_block_comment = 0
  }

  {
    code = strip_comments($0)
    sub(/^[[:space:]]+/, "", code)
    sub(/[[:space:]]+$/, "", code)

    if (code == "") {
      next
    }

    for (setting in managed) {
      boundary = "^" setting "([[:space:]]|\\[|=)"
      if (code !~ boundary) {
        continue
      }

      assignment = "^" setting \
                   "([[:space:]]*\\[[^]]+\\])*" \
                   "[[:space:]]*="

      if (code !~ assignment) {
        printf "::error file=%s,line=%d::Unsupported assignment syntax for %s.\n",
               FILENAME, FNR, setting
        bad = 1
        next
      }

      value = code
      sub(assignment "[[:space:]]*", "", value)
      sub(/[[:space:]]+$/, "", value)

      if (value == "") {
        printf "::error file=%s,line=%d::%s has an empty value.\n",
               FILENAME, FNR, setting
        bad = 1
        next
      }

      if (value ~ /[$][(]/ || value ~ /[$][{]/) {
        printf "::error file=%s,line=%d::%s uses variable expansion; managed settings must have one literal authority and may not use $(inherited).\n",
               FILENAME, FNR, setting
        bad = 1
        next
      }

      if (value !~ /^[[:alnum:]_.+-]+$/) {
        printf "::error file=%s,line=%d::%s must be one literal token; continuations and compound values are not accepted.\n",
               FILENAME, FNR, setting
        bad = 1
        next
      }

      printf "%s\t%s:%d\t%s\n",
             setting, FILENAME, FNR, value
    }
  }

  END {
    if (in_block_comment) {
      printf "::error file=%s,line=%d::Unterminated block comment in xcconfig.\n",
             block_start_file, block_start_line
      bad = 1
    }

    if (bad) {
      exit 2
    }
  }
' "$@" >"$config_records"
then
  cat "$config_records"
  echo "::error::Config/*.xcconfig could not be reduced to authoritative literal values."
  exit 1
fi

expected_values="$guard_tmp/expected-values.tsv"
: >"$expected_values"

for setting in $managed_settings; do
  raw_values="$guard_tmp/$setting.raw"
  unique_values="$guard_tmp/$setting.unique"

  if ! awk -F '	' -v setting="$setting" '
    $1 == setting { print $3 }
  ' "$config_records" >"$raw_values"
  then
    echo "::error::Failed to collect Config values for $setting."
    exit 1
  fi

  if ! LC_ALL=C sort -u "$raw_values" >"$unique_values"; then
    echo "::error::Failed to normalize Config values for $setting."
    exit 1
  fi

  value_count=$(awk 'END { print NR + 0 }' "$unique_values")
  if [ "$value_count" -ne 1 ]; then
    if [ "$value_count" -eq 0 ]; then
      echo "::error::$setting is not declared in Config/*.xcconfig."
    else
      echo "::error::$setting has $value_count competing Config values:"
      awk -F '	' -v setting="$setting" '
        $1 == setting {
          printf "  %s => %s\n", $2, $3
        }
      ' "$config_records"
    fi
    exit 1
  fi

  expected_value=$(sed -n '1p' "$unique_values")
  printf '%s\t%s\n' "$setting" "$expected_value" >>"$expected_values"
done

# ---------------------------------------------------------------------------
# Third invariant: every supported build configuration must resolve exactly the
# unique value established above.
#
# One configuration is not the policy. Asking xcodebuild for its default
# resolves whichever configuration happens to be default and says nothing about
# the others — a Release binding could rot entirely while that check stayed
# green. Each configuration is therefore named explicitly and asserted on its
# own.
# ---------------------------------------------------------------------------
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "::error::xcodebuild is unavailable; no managed setting can be resolved. This is a runner problem, not a build-settings one."
  exit 1
fi

for configuration in $managed_configurations; do
  build_settings="$guard_tmp/build-settings-$configuration.txt"

  if ! xcodebuild \
         -project ZenAgent.xcodeproj \
         -scheme ZenAgent \
         -configuration "$configuration" \
         -showBuildSettings \
         >"$build_settings" 2>&1
  then
    echo "::error::xcodebuild -showBuildSettings -configuration $configuration failed:"
    tail -n 40 "$build_settings"
    exit 1
  fi

  for setting in $managed_settings; do
    expected_value=$(awk -F '	' -v setting="$setting" '
      $1 == setting {
        print $2
        exit
      }
    ' "$expected_values")

    resolved_raw="$guard_tmp/$configuration-$setting.resolved-raw"
    resolved_unique="$guard_tmp/$configuration-$setting.resolved-unique"

    if ! awk -v setting="$setting" '
      {
        pattern = "^[[:space:]]*" setting \
                  "[[:space:]]*=[[:space:]]*"
      }

      $0 ~ pattern {
        value = $0
        sub(pattern, "", value)
        sub(/[[:space:]]+$/, "", value)
        if (value != "") {
          print value
        }
      }
    ' "$build_settings" >"$resolved_raw"
    then
      echo "::error::Failed to parse the $configuration value xcodebuild resolved for $setting."
      exit 1
    fi

    if ! LC_ALL=C sort -u "$resolved_raw" >"$resolved_unique"; then
      echo "::error::Failed to normalize the $configuration values xcodebuild resolved for $setting."
      exit 1
    fi

    resolved_count=$(awk 'END { print NR + 0 }' "$resolved_unique")
    if [ "$resolved_count" -ne 1 ]; then
      echo "::error::in $configuration, $setting resolved to $resolved_count distinct values; expected exactly one:"
      sed 's/^/  /' "$resolved_unique"
      exit 1
    fi

    resolved_value=$(sed -n '1p' "$resolved_unique")
    if [ "$resolved_value" != "$expected_value" ]; then
      echo "::error::in $configuration, $setting resolved to '$resolved_value'; Config/*.xcconfig authoritatively declares '$expected_value'."
      exit 1
    fi

    echo "OK: $configuration $setting = $resolved_value"
  done
done
