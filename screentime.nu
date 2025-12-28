#!/usr/bin/env nu

# RIGHT NOW: Rewriting the rules according to new spec, line 156, adding new keys to the definition, on t

# # v0.1.0 TODOs
#
# TODO add depends= key
# TODO implement offline_time, after_boot_allowed in the new system
# TODO implement counter_reset, state_reset. day start is 4am. you can use the real_time check for it, don't depend on systemd please
# TODO a mechanism to only increment the counter if the user is logged in
# TODO implement and document how to trust the OS clock
# TODO notify should work, libnotify (notify-send), but not as a hard dependency
# TODO document dependency (notify-send)
# TODO implement testing as specified in the bottom
# TODO installation instructions for NixOS
# TODO publish as Github release.
# TODO ensure counter updates and real time clock are accurate
# TODO support different timezones
# TODO set as main and publish on Github as a release.
#
# LATER TODOs
#
# TODO implement specifying which rules apply to which users
# TODO implement parallelization for each layer
# TODO implement custom rules in using nu modules and export/use
# TODO implement syntax checking of user-provided custom rules with nu-check
# TODO trigger on logins too (watch logins file or similar)
# TODO adopt Nix
# TODO make it cross-platform
# TODO installation instructions for Linux, Windows, MacOS
# TODO implement performance profiling (resource usage warnings for rules etc.)

const VERSION = '0.1.0'
const DATA_DIR = '/var/lib/screentimer/dev'
const CONFIG_FILE = '/etc/screentimer/config.toml'

const ITERATION_INTERVAL = 20sec
# The duration between the successive iterations of the program loop.

const COMMIT_INTERVAL = 1min
# The period at which state data is saved to disk.

let rules: table<key: string, enable: bool, update_state: closure, state_reset: record, priority: int, block: closure, counter: closure, > = [
    {
        key: 'real_time'
        state_reset: 'on_boot'
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
                            now: $now
                            # We fetch the uptime again, because connecting to google.com might have taken some time.
                            now_minus_uptime: $now - (sys host).uptime,
                            online: true,
                        }
                    } catch { null }
                } else { null }
            } else if $online == true {
                $state | update now {$uptime + $state.now_minus_uptime}
            } else {
                make-error impossible 'd0bf1267-0741-4818-8d34-09b0224d64cf'
            }
        }
    }
    {
        key: 'allowed_times'
        priority: 1
        condition: {|params| $params.rule_states.real_time.now? != null }
        update_state: {|params|
            let now: datetime = $params.rule_states.real_time.now;
            $params.state | default {
                { parsed_allowlist: (
                    $params.config
                    | each {|str|
                        str trim
                        | parse -r '(?<start>\S+)\s*-\s*(?<end>\S+)'
                        | if ($in | is-empty) {
                            print -e $"The value provided to 'allowed_times' config option is in an invalid format:\n($in) \n\nIt should be in the format \"08:00 - 16:00\""
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
                let hour: duration = $now - ('0am' | into datetime)
                $row.parsed_allowlist
                | all {|it|
                    $hour < $it.start or $hour > $it.end
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
            let outside = $params.states.allowed_times?.outside? | default false
            (not $outside) and (not $params.state.exceeded)
        }
        block: {|params| $params.state.exceeded }
    }
    # Extra time rule.
    # If both allowed_times and total_time rules don't exist this rule shouldn't run.
    {
        key: 'extra_time'
        priority: 2
        condition: {|params| $params.states.total_time.exceeded? != null }
        counter: {|params|
                let total_exceeded = $params.states.total_time.exceeded? | default false
                let outside_allowed = $params.states.allowed_times?.outside? | default false
                ($outside_allowed or $total_exceeded) and not ($params.counter > $params.config)
        }
        block: {|params| $params.counter > $params.config }
    }
]

# An utility to manage screen time controls.
# For more info: https://github.com/rayanamal/screentimer
def main [
    --config-file (-c): path # Specify an alternative configuration file.
]: nothing -> nothing {

    # Get program configuration.
    let config_file: path = $CONFIG_FILE | path expand
    if not ($config_file | path exists) {
        print -e $"Error: No configuration file found at path ($config_file)"
        exit 1
    }
    let config = open $config_file | get config

    # Initialize the data directory.
    let data_dir: path = $DATA_DIR | path expand
    let data_file = $data_dir | path join 'data.nuon'
    mkdir $data_dir

    loop {
        if ((sys host).uptime mod $COMMIT_INTERVAL) < $ITERATION_INTERVAL {
            $data | save -f $data_file
        }

        let results = run-rules
        $data.counters = $results.counters
        $states = $results.states
        sleep $ITERATION_INTERVAL
    }
    ignore
}

# Run the given rules, according to the flow of operation defined in the docs
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

# 	let allowed_times = $config.allowed_times | parse-allowlist
# 	let last_reset = (v last_reset | into datetime)
# 	mut next_reset = $last_reset + 1day

# 	loop {
# 		let online: bool = (
# 			ping -c 5 8.8.8.8
# 			| complete
# 			| $in.exit_code == 0
# 		)
# 		if $online {
# 			if not (is-time-allowed "now" $allowed_times) {
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

# Create an error with a Github issue link for a situation that should never have happened,
# like an inexhaustive match that was thought to be exhaustive.
def "make-error impossible" [
    uuid: string # A v4 UUID. Can be obtained by `random uuid` command.
] {
    let title = $"Runtime error: ($uuid | split row '-' | first)" | url encode
    let body = $"
An unknown error has occurred during runtime.

`screentimer` version: ($VERSION)
`nu` version: (version | get version)
Issue UUID: ($uuid)

Briefly describe what happened:
" | url encode
    let url = $"https://github.com/rayanamal/screentimer/issues/new?title=($title)&body=($body)"
    make-error $"An unknown error has occurred. We're sorry. Please click (ansi u)($url | ansi link --text 'here')(ansi reset) to report it so that it can be fixed."
}

# Create an error with a reason.
def make-error [reason: string] {
    error make --unspanned { msg: $reason }
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
