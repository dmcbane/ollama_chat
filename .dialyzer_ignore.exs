# .dialyzer_ignore.exs
#
# This file contains patterns for Dialyzer warnings that should be ignored.
# Use this sparingly and only for known issues that cannot be easily fixed.
#
# Format:
# {"path/to/file.ex", :warning_type, line_number},
# {"path/to/file.ex", :warning_type}, # ignore all warnings of this type in file
# {:warning_type}, # ignore this warning type everywhere
#
# Common warning types:
# - :unknown_function
# - :unknown_type
# - :call
# - :contract_diff
# - :contract_subtype
# - :contract_supertype
# - :extra_range
# - :invalid_contract
# - :no_return
# - :opaque
# - :race_condition
# - :unmatched_return
# - :unused_fun

[
  # Add warning patterns to ignore here
  # Example: {"lib/my_module.ex", :unknown_function, 42}
]
