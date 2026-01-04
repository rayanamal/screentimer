# Restriction rules implementation

Implementing screen time constraints for digital devices is a problem with high inherent complexity. There are many edge cases, and few solutions which result in low cognitive overhead for both the system administrator and the user. Thus, this program was designed around three goals (in this order of priority):

1. Ensure correctness
  - Screen time rules should always run as specified.
2. Ensure predictability
  - Screen time rules should behave intuitively and predictably. Rules shouldn't interact in hard to predict ways.
3. Simplify the end-user configuration interface
  - Provide a simple configuration interface for both technical users and normal users.

### The program loop
 
 1. Wait for 20 seconds.
 2. Check `state_reset` and `counter_reset` triggers, and reset them if necessary.
 3. Run `update_state` closures of the rules who have it set. Update ther states accordingly.
 4. Run `condition` closures of the rules who have it set. Filter out the rules which 
    return false for the next steps.
 5. Run `counter` closures of the rules who have it set. Update their counters accordingly.
 6. Run `block` closures of the rules who have it set and collect the results. 
 7. Determine whether or not to block the user based on the results and relative priorities
    of the rules. If the final result is `true`, terminate the user's session.
 8. Go to 1.
 
### Don't change any part of the code without first fully understanding the program!
 
This is a logic-heavy codebase, and there are a lot of footguns because of the problem space. If you didn't fully understand the principles and reasoning behind this program's operation, don't change it.
 
This design ensures reliability and predictability, it ensures that an arbitrary number of user-provided rules can coexist with each other, without interfering with each other in unintended ways, all while providing an interface for configuration that remains easily understandable and easily customizable by humans.
 
#### Data flow is strictly downwards
 
In every iteration of the loop, data flows strictly from an upper layer to the next layer (see the program loop above). There is no data sharing inside a single layer. The only pieces of data that are allowed to persist between runs are explicitly designated as such: the state variables and the counters.

Here's an example of how a seemingly small change that affects data flow can break the guarantees we provide:
 
If the code were changed so that the `update_state` closure of rules had access to the state variables of other rules from the current iteration, it would result in a situation where the order in which rules' state updates are run would matter. This would break the ability for arbitrary rules to coexist.

Similarly, if the `update_state` closure was given access to to the state variables of other rules from the *previous* iteration, it would increase cross-rule state interference and would result in decreased predictability.

## Specifying rules

All rules are specified in the `rules/` directory as nu modules.

All rules are disabled by default. The user must enable a rule explicitly by either setting a configuration value or by setting the `enable` key for the rule to `true` in the configuration file.

  - `key` (`string`): 
      The key in the configuration file identifying this rule. Also should be the name of the rule module file.
    
  - `dependencies` (optional) (`list<string>`):
      The list of other rules this rule depends on. If the specified rules are not enabled, this rule will not run.
 
  - `update_state` (optional) (`closure`):
      Parameters: rule parameters (`record`)
      Output: `any`
      A closure to run to update the state variable of this rule.
      State variable of the rule will be set to the output of this closure.
      If it returns `null`, state variable will not be updated.
 
  - `state_reset` (optional) (`record`):
      If given, the state variable will be reset when this is triggered.
      - `on` (`string`):
          These are the possible options:
          - `on_boot` to reset when screentimer starts (typically when the computer boots up).
          - `weekly`, `daily`, `monthly`
          - A string in the form: `'every {integer} {hour(s)/day(s)/week(s)/year(s)/nu-parseable duration} [starting at {nu-parseable datetime}]'`
      - `condition` (optional) (`closure`):
          Parameters: rule parameters (`record`)
          Output: `bool`
          A closure to run when triggered to determine whether to reset state.
 
  - `condition` (optional) (`closure`):
      Parameters: rule parameters (`record`)
      Output: `bool`
      A closure to run to determine whether to run the rule in this iteration.
 
  - `counter` (optional) (`closure`):
      Parameters: rule parameters (`record`)
      Output: `bool`
      If given, a time counter will be stored on disk for this rule.
      All counters are reset at $config.day_start, if it wasn't possible (e.g. because 
      the computer was not turned on) they will be reset at the earliest possible time after that.
 
  - `counter_reset` (optional) (`record`):
      - on (`string`):
          If given, the counter will be reset when this is triggered. 
          See the state_reset key for a list of possible options.
      - condition (optional) (`closure`):
          Parameters: rule parameters (`record`)
          Output: `bool`
          A closure to run when triggered to determine whether to reset the counter.
 
  - `block` (optional) (`closure`):
      Parameters: rule parameters (`record`)
      Output: `bool`
      A closure to run to determine whether to block the system.
      If the output is nothing (null), the rule will have no effect on blocking.

  - `priority` (optional) (`int`):
      Blocking priority of the rule relative to other rules (see below).
      Rules with higher priority override the block decision of rules with lower priority.
      The results of rules with the same priority are OR'ed. 
      This means if any one rule results in block decision, the system is blocked.
 
### State variables
Rules can persist data between runs and share data with other rules using their state variable. State variables are saved to disk periodically (every minute).
 
### Rule parameters (`record`):
 - rule_states (optional) (`record`): State variables of all rules, with rule ids as keys, if there are any rules which update their state.
 - state (optional) (`any`): This rule's state variable, if the update_state key is defined for the rule.
 - config (optional) (`any`): This rule's configuration value, if it's specified in the configuration file.
 - counter (optional) (`duration`): This rule's counter, if the counter key is defined for the rule. Defaults to 0 seconds.
 
## Built-in rules

TODO describe the built-in rules and their configuration options

## Creating your own rules

TODO describe how to create your own custom rules.  
