#!/usr/bin/env nu

# RIGHT NOW: rewriting the config.toml file

# # v0.1.0 TODOs
#
# TODO implement counter_reset, state_reset. day start is 4am by default. you can use the real_time check for it, don't depend on systemd please
# TODO a mechanism to only increment the counter if the user is logged in
# TODO implement and document how to trust the OS clock
# TODO notify should work, libnotify (notify-send), but not as a hard dependency.
# TODO implement per day-of-week schedules for relevant rules
# TODO ensure counter updates and real time clock are accurate
# TODO ensure everything specified in config.toml is implemented (timezones, users=, etc.)
# TODO bake-in conf-switcher's delayed application feature for screentimer configuration
#   It's needed because screentimer should be usable outside NixOS and outside Linux
# TODO rewrite README
# TODO implement testing as specified in the bottom
# TODO set as main and publish on Github as a release.
#
# LATER TODOs
#
# TODO only pass the state variables of the rules explicitly stated dependencies
# TODO explicitly register and initialize state variables, like ESPHome globals
# TODO implement until= and after= keys to specify timestamps for when rules should run
# TODO adopt Nix
# TODO support configuring through NixOS module (per-specialization rules enabling)
# TODO support configuration hotreloading (call a templated systemd service to change configurations)
# TODO implement specifying which rules apply to which users
# TODO implement parallelization for each layer
# TODO implement custom rules using nu modules and export/use
# TODO implement syntax checking of user-provided custom rules with nu-check
# TODO trigger on logins too (watch logins file or similar)
# TODO integrate Chromium settings (wrap Chromium in your module, overlay or whatever)
# TODO reverse DNS firewall, integrated with (but independent of) screentimer
# TODO community created whitelists and blacklists
# TODO make it cross-platform. Other platforms including Linux will necessarily lack almost all features, like specializations and the ability to pair with Chromium lists. It's basically meant as a try-on gateway drug to our NixOS config.
# TODO implement performance profiling (resource usage warnings for rules etc.)
# TODO rewrite in Rust, bundle everything into a single executable

const VERSION = '0.1.0'
const DATA_DIR = '/var/lib/screentimer/dev'
const CONFIG_DIR = '/etc/screentimer/'

const ITERATION_INTERVAL = 20sec
# The duration between the successive iterations of the program loop.

const COMMIT_INTERVAL = 1min
# The period at which state data is saved to disk.

# Type signature: table<key: string, enable: bool, update_state: closure, state_reset: record<on: string, condition: closure>, counter: closure, counter_reset: record<on: string, condition: closure>, block: closure, priority: int>

let default_rule = {
    key: "default"
    enable: true
    update_state: {||}
    state_reset: { on: "on_boot", condition: {||} }
    counter: {||}
    counter_reset: { on: "on_boot", condition: {||} }
    block: {||}
    priority: 0
}

let rules = [
    {
        key: 'real_time'
        state_reset: { on: "on_boot" }
        update_state: {|params|
            let uptime = (sys host).uptime
            let state = $params.state? | default {}
            let online: bool = $state.online? | default false
            if $online == false {
                let last_run = $state.last_run? | default {0 | into datetime}
                if ($uptime - $last_run) > 1min {
                    try {
                        let now: datetime = (
                            http head --max-time 2sec https://google.com
                            | transpose -rd
                            | get date
                            | into datetime
                        )
                        {
                            now: $now,
                            # We fetch the uptime again, because connecting to google.com might have taken some time.
                            now_minus_uptime: ($now - (sys host).uptime),
                            online: true
                        }
                    } catch { null }
                } else { null }
            } else if $online == true {
                $state | update now {$uptime + $state.now_minus_uptime}
            } else { unreachable 'd0bf1267-0741-4818-8d34-09b0224d64cf' }
        }
    }
    {
        key: 'allow_schedule'
        priority: 1
        dependencies: [ 'real_time' ]
        condition: {|params| $params.rule_states.real_time.online? | default false }
        update_state: {|params|
            let now: datetime = $params.rule_states.real_time.now;
            $params.state | default {
                { parsed_allowlist: (
                    $params.config
                    | each {|str|
                        str trim
                        | parse -r '(?<start>\S+)\s*-\s*(?<end>\S+)'
                        | if ($in | is-empty) {
                            print -e $"The value provided to 'allow_schedule' config option is in an invalid format:\n($in) \n\nIt should be in the format \"08:00 - 16:00\""
                            exit 1
                        } else {}
                        | update cells {
                            str trim
                            | str replace -a '.' ':' # Some locales (in theory) delimit hours with a dot instead of a semicolon.
                            | into datetime
                            | $in - ("0am" | into datetime)
                        }
                        | into record
                        | if ($in.start > $in.end) {
                            print -e $"Start time ($in.start) is after end time ($in.end) in the provided input string: ($str)"
                            exit 1
                        } else {}
                    }
                )}
            }
            | upsert outside {|row|
                let now_duration: duration = $now - ('0am' | into datetime)
                $row.parsed_allowlist
                # If we're not inside of all ranges, then return true
                | all {|it|
                    $now_duration < $it.start or $now_duration > $it.end
                }
            }
        }
        block: {|params| $params.state.outside }
    }

    # Total time rule.
    {
        key: 'total_time'
        priority: 1
        update_state: {|params|
            { exceeded: ($params.counter > $params.config) }
        }
        counter: {|params|
            let outside = $params.rule_states.allow_schedule?.outside? | default false
            (not $outside) and (not $params.state.exceeded)
        }
        block: {|params| $params.state.exceeded }
    }
    
    # Online extra time rule.
    {
        key: 'online_extra_time'
        priority: 2
        dependencies: [ 'real_time', 'total_time', 'allow_schedule' ]
        condition: {|params| $params.rule_states.real_time.online? | default false }
        counter: {|params|
                let total_exceeded = $params.rule_states.total_time.exceeded? | default false
                let outside_allowed = $params.rule_states.allow_schedule.outside? | default false
                ($outside_allowed or $total_exceeded) and not ($params.counter > $params.config)
        }
        block: {|params| $params.counter > $params.config }
    }
    
    # Offline extra time rule.
    # Unlike the online extra time rule, this rule doesn't have a hard dependency on real_time rule.
    {
        key: 'offline_extra_time'
        priority: 2
        dependencies: [ 'total_time', 'allow_schedule' ]
        condition: {|params| not ($params.rule_states.real_time?.online? | default false) }
        counter: {|params|
                let total_exceeded = $params.rule_states.total_time.exceeded? | default false
                let outside_allowed = $params.rule_states.allow_schedule.outside? | default false
                ($outside_allowed or $total_exceeded) and not ($params.counter > $params.config)
        }
        block: {|params| $params.counter > $params.config }
    }
    
    # After boot allowed time rule.
    {
        key: 'allow_after_boot'
        priority: 3
        block: {|params|
            if (sys host).uptime < $params.config { false }
        }
    }
]

$rules | each {|it| typecheck $default_rule | print $it.key $in}

exit

# A utility to manage screen time controls.
# For more info: https://github.com/rayanamal/screentimer
def main [
    --config-file (-c): path # Specify an alternative configuration file.
]: nothing -> nothing {

    # Get program configuration.
    let config_file: path = $CONFIG_DIR | path expand | path join 'config.toml' 
    if not ($config_file | path exists) {
        print -e $"Error: No configuration file found at path ($config_file)"
        exit 1
    }
    let config = open $config_file | get config
    
    # Initialize the data directory and data global variable.
    let data_dir: path = $DATA_DIR | path expand
    let data_file = $data_dir | path join 'data.nuon'
    mkdir $data_dir
    mut data = {};
        
    # 1. find out which rules should be run based on their enable= and dependencies=
    # 2. get into the loop
    
    let rules_path: path = $CONFIG_DIR | path expand | path join 'rules/'
    if ($rules_path | path exists) {
        ls $rules_path | each {
            #NEXT 
        }
    }
    
    loop {
        if ((sys host).uptime mod $COMMIT_INTERVAL) < $ITERATION_INTERVAL {
            $data | save -f $data_file
        }

        # let results = run-rules
        #TODO update data variable here
        sleep $ITERATION_INTERVAL
    }
    ignore
}

# Run the given rules, according to the program loop operation defined in the docs
# Output: new counters and states.
def run-rules [real_now: datetime, config: record, counters: record, states: record, rules: table] {

    let states = (
        $states
        | merge (
            $rules
            | where {$in has update_state}
            | each {|rule|
                let rule_params = {
                    real_now: $real_now
                    config: ($config | get $rule.id)
                    counter: ($counters | get $rule.id)
                    state: ($states | get $rule.id)
                }

                { $rule.id: (do $rule.update_state $rule_params) }
            }
            | into record
    ))

    let counters = (
        $counters
        | merge (
            $rules
            | where {$in has counter}
            | each {|rule|
                let rule_params = {
                    real_now: $real_now
                    config: ($config | get $rule.id)
                    counter: ($counters | get $rule.id)
                    state: ($states | get $rule.id)
                }
                let new_counter = (
                    $counters
                    | get $rule.id
                    | if (do $rule.counter $rule_params $states) {
                         $in + $ITERATION_INTERVAL
                    } else {}
                )
                { $rule.id: $new_counter }
            }
            | into record
    ))

    $rules
    | group-by priority --to-table
    | sort-by priority --reverse
    | get items
    | reduce --fold null {|group, acc|
        if $acc != null {
            $acc
        } else {
            $group
            | each {|rule|
                let rule_params = {
                    real_now: $real_now
                    config: ($config | get $rule.id)
                    counter: ($counters | get $rule.id)
                    state: ($states | get $rule.id)
                }
                do $rule.block $rule_params $states
            }
            | where {$in != null}
            | if ($in | is-not-empty) {
                reduce --fold false {|it, acc| $acc or $it }
            }
        }
    }
    | if $in == true {
        if (sys host).uptime >= $config.after_boot_allowed {
            # print "User is blocked." ; exit # for testing
            loginctl list-users --json short
            | from json
            | get user
            | each {|user|
                if $user in $config.users {
                    loginctl kill-user $user # Using loginctl terminate-user doesn't work, because for some reason it also kills the login manager (SDDM) and non-technical users are left with a tty console.
                    print $"User \"($user)\" is terminated."
                }
            }
        }
    }
}

# def main []: nothing -> nothing {
# 	# alias notify = notify-send -a "screentime-nixos" -s "1 minute left to termination" -t "Your user session will be terminated in 60 seconds." --timeout 60sec
# 	# notify

# 	let allow_schedule = $config.allow_schedule | parse-allowlist
# 	let last_reset = (v last_reset | into datetime)
# 	mut next_reset = $last_reset + 1day

# 	loop {
# 		let online: bool = (
# 			ping -c 5 8.8.8.8
# 			| complete
# 			| $in.exit_code == 0
# 		)
# 		if $online {
# 			if not (is-time-allowed "now" $allow_schedule) {
# 				set extra ((v extra) + 1min)
# 				if (v extra) == 1min or (v extra) > $EXTRA_MINS {
# 					block
# 				} else if (v extra) == $EXTRA_MINS {
# 					# notify
# 				}
# 			}
# 			if (date now) > $next_reset {
# 				set last_reset ($next_reset | into int)
# 				$next_reset = $next_reset + 1day
# 				set extra 0min
# 				set offline 0min
# 			}
# 		} else if not $online {
# 			set offline ((v offline) + 1min)
# 			if (v offline) > $MAX_OFFLINE {
# 				# if (v offline_block_counter) >= 3 {
# 				# 	set offline_block_counter 0
# 					block
# 				# } else {
# 				# 	set offline_block_counter ((v offline_block_counter) + 1)
# 				# }
# 			} else if (v offline) == $MAX_OFFLINE {
# 				# notify
# 			}
# 		}
# 		sleep (1min - (4sec + 40ms)) # every interval between pings take 1.01 seconds and we ping 5 times.
# 		# sleep 100ms # for testing
# 	}
# }

def "main list-timezones" []: nothing -> table<timezone: string> {
	date list-timezone
}

def block []: nothing -> nothing {

}

# Create an error with a Github issue link for a situation that should never happen.
def unreachable [
    uuid: string # A v4 UUID. Can be obtained by `random uuid` command.
] {
    let title = $"Runtime error: ($uuid | split row '-' | first)" | url encode
    let body = $"
An unknown error has occurred during runtime.

`screentimer` version: ($VERSION)
`nu` version: (version | get version)
Issue UUID: ($uuid)
" | url encode
    let url = $"https://github.com/rayanamal/screentimer/issues/new?title=($title)&body=($body)"
    make-error $"An unknown error has occurred. We're sorry. Please click (ansi u)($url | ansi link --text 'here')(ansi reset) to report it so that it can be fixed."
}

# Create an error with a reason.
def make-error [reason: string] {
    error make --unspanned { msg: $reason }
}

# Get the base type of a value provided either as an argument or from the input. 
# Base types comprise 'list', 'record', and all basic types. Tables are recognized as lists.
def type-of [value: any]: nothing -> string { ignore
	$value
	| describe --detailed
	| get type
}

def typecheck [template]: any -> bool {
    traverse {|it, cell_path|
        ($template | get -o $cell_path) != null and (type-of $it) == (type-of ($template | get $cell_path))
    } {|it, cell_path|
        if (type-of $it) == 'record' { values } else { $in }
        | all {}
    }
}

# Run a closure on every basic value contained in structured values.
def traverse [
	closure?: closure               # If given, run this closure on every basic value. Parameters: the input value (any), the cell path (string). Input: the basic value (any).
	structured_closure? : closure   # If given, run this closure on structured values themselves, after all their children are traversed. Parameters: the input value (any), the cell path (cell-path). Input: the structured value (any).
]: any -> any {
	_traverse ($closure | default {{||}}) ($structured_closure | default {{||}}) $.
}

def _traverse [closure: closure, structured: closure, cell_path: cell-path]: any -> any {
    let input
	| match (type-of $in) {
        'list' => {
            enumerate
            | each {|e|
                let new_path: cell-path = $cell_path | split cell-path | append ($e.index | into cell-path | split cell-path) | into cell-path
                $e.item | _traverse $closure $structured $new_path
            }
            | do $structured $in $cell_path
        }
        'record' => {
            items {|key, value|
                let new_path: cell-path =  $cell_path | split cell-path | append ([$key] | into cell-path | split cell-path) | into cell-path
                $value | _traverse $closure $structured $new_path
                | {$key: $in}
            }
            | into record
            | do $structured $in $cell_path
		}
		_ => { do $closure $in $cell_path }
	}
}

# Later TODOs

# TODO fix depman
# TODO port tests to depman
# TODO use version to determine config file upgrade, using semver. Upgrade is a merge operation.
# TODO implement a version subcommand to print out version.
# TODO rules are only the ones named in the config file and no more, verification.
# TODO check whether running with admin privileges (is-admin)

# # Testing
#
# ### Inputs:
# - run-period: run every simulated period
# - duration: run for simulated duration
# - start: run starting from simulated start
# - different rules record
# - different config file
# - use-attempt: simulated usage attempt hour ranges, in the allowlist format
#
# ### Output:
# table of ran-hour, block decisions of all rules
#
# ### Assertions:
# table of hour, expected block decisions of all rules
