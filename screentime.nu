#!/usr/bin/env nu

# RIGHT NOW: Rewriting the checks according to new spec, line 171.

# v0.1.0 TODOs
#
# TODO enable experimental option enforce-runtime-checks
# TODO implement offline_time in the new system
# TODO ensure counter updates and real time clock are accuracte 
# TODO implement parallelization for each layer
# TODO implement user-configurable checks in config.toml
# TODO implement syntax checking of user-provided checks' closures with nu-check
# TODO implement and document how to trust the OS clock
# TODO a mechanism to only increment the counter if the user is logged in
# TODO account for timezone
# TODO notify should work, you can use libnotify (notify-send)
# TODO document dependencies (systemd, notify-send)
# TODO implement testing as specified in the bottom
# TODO implement specifying different config file

# LATER TODOs
# TODO adopt Nix
# TODO make it cross-platform
# TODO implement performance profiling (resource usage warnings for checks etc.)

const VERSION = '0.1.0'
const DATA_DIR = '/var/lib/screentimer/dev'
const CONFIG_FILE = '/etc/screentimer/config.toml'

const ITERATION_INTERVAL = 20sec 
# The duration between the successive iterations of the program loop.

const COMMIT_INTERVAL = 1min 
# The period at which state data is saved to disk.

# # Restriction checks implementation
# 
# Implementing screen time constraints for digital devices is a treacherously complex task. There are many edge cases,
# and few solutions which result in low cognitive overhead for the system administrator.
# 
# You can set screen time checks in a declarative manner.
# The program loop runs every 20 seconds and processes every check.
# 
# ### The program loop
# 
#   1. Wait for 20 seconds.
#   2. Check `state_reset` and `counter_reset` triggers, and reset them if necessary.
#   3. Run `update_state` closures of the checks who have it set. Update ther states accordingly.
#   4. Run `condition` closures of the checks who have it set. Filter out the checks which 
#      return false for the next steps.
#   5. Run `counter` closures of the checks who have it set. Update their counters accordingly.
#   6. Run `block` closures of the checks who have it set and collect the results. 
#   7. Determine whether or not to block the user based on the results and relative priorities
#      of the checks. If the final result is `true`, terminate the user's session.
#   8. Go to 1.
# 
# ### Don't change any part of the code without first fully understanding the program!
# 
# This is a logic-heavy codebase, and there are a lot of footguns because of the problem space. 
# If you didn't fully understand the principles and reasoning behind this program's operation, 
# don't change it.
# 
# This design ensures reliability and predictability, it ensures that an arbitrary number of 
# user-provided checks can coexist with each other, without interfering with each other in 
# unintended ways, all while providing an interface for configuration that remains 
# easily understandable and easily customizable by humans.
# 
# #### Data flow is strictly downwards
# 
# In every iteration of the loop, data flows strictly from an upper layer to the next layer (see 
# the program loop above).
# There is no data sharing inside a single layer. The only pieces of data that are allowed to 
# persist between runs are explicitly designated as such: the state variables and the counters.
#
# Here's an example of how a seemingly small change that changes this can break the guarantees 
# we provide:
# 
# If the code were changed so that the `update_state` closure of checks had access to the state 
# variables of other checks from the current iteration, it would result in a situation where the 
# order in which checks' state updates are run would matter. This would break the ability for 
# arbitrary checks to coexist.
# 
# Similarly, if the `update_state` closure was given access to to the state variables of other 
# checks form the *previous* iteration, it would increase cross-check state interference and 
# would result in decreased predictability.
#
# ## Check structure
#   - key (string): 
#       The key in the configuration file identifying the check.
# 
#   - enable (optional) (bool):
#       Whether to enable the check. Defaults to true.
# 
#   - update_state (optional) (closure):
#       Parameters: check parameters (record)
#       Output: any
#       A closure to run to update the state variable of this check.
#       State variable of the check will be set to the output of this closure.
#       If it returns nothing (null), state variable will not be updated.
# 
#   - state_reset:
#       If given, the state variable will be reset when this is triggered.
#       These are the possible options:
#       - 'on_boot' to reset when screentimer starts up (typically when the computer boots up).
#       - 'weekly', 'daily', 'monthly'
#       - A string in the form: 'every {integer} {hour(s)/day(s)/week(s)/year(s)/nu-parseable duration} [starting at {nu-parseable datetime}]'
# 
#   - condition (optional) (closure):
#       Parameters: check parameters (record), all states (record)
#       Output: bool
#       A closure predicate to run to determine whether to run the check in this iteration.
# 
#   - counter (optional) (closure):
#       Parameters: check parameters (record), all states (record)
#       Output: bool
#       If given, a time counter will be stored on disk for this check.
#       All counters are reset at $config.day_start, if it wasn't possible (e.g. because 
#       the computer was not turned on) they will be reset at the earliest possible time after that.
# 
#   - counter_reset: (optional) (string):
#       If given, the counter will be reset when this is triggered.
#       See the state_reset key for the possible options.
# 
#   - block (optional) (closure):
#       Parameters: check parameters (record), all states (record).
#       Output: bool
#       A closure to run to determine whether to block the system.
#       If the output is nothing (null), the check will have no effect on blocking.
#
#   - priority (optional) (int): 
#       Blocking priority of the check relative to other checks (see below).
#       Checks with higher priority overrides the block decision of checks with lower priority.
#       The results of checks with the same priority are OR'ed. 
#       This means if any one check results in block decision, the system is blocked.
#       Checks with the same type will be grouped together before considering priority.
#       This means checks with different types won't affect each other.
# 
# ### State variables
# Checks can persist data between runs and share data with other checks using their state 
# variable.
# State data is kept in memory and saved to disk periodically.
# 
# ### check parameters (record):
#   - config (any): this check's configuration value as defined in the configuration file.
#   - counter (optional) (duration): this check's counter, if the counter key is defined for the check.
#   - state (optional) (any): this check's state variable, if the update_state key is defined for the check.
# 
# ### all states (record):
# This is a record containing state variables of all checks, with check ids as keys.

let checks: table<key: string, priority: int, block: closure, counter: closure, update_state: closure> = [
    {
        key: 'real_time'
        state_reset: 'on_boot'
        update_state: {|params|            
            let uptime = (sys host).uptime
            let online = $params.state.online? | default false
            
            if $online == false {
                let last_run = $params.state.last_run? | default {0 | into datetime}
    
                if ($uptime - $last_run) > 1min {
                    let now_minus_uptime = try {
                        http head --max-time 2sec https://google.com
                        | transpose -rd
                        | get date
                        | into datetime
                        | $in - (sys host).uptime
                    } catch { null }
                }
            } else if $online == true {
                
            } else {
                make-error impossible 'd0bf1267-0741-4818-8d34-09b0224d64cf'
            }
        }
    }
    {
        key: 'allowed_times'
        priority: 1
        type: 'online'
        update_state: {|params|
            if $params.state? == null {
                let parsed_allowlist = (
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
                )
                { parsed_allowlist: $parsed_allowlist }
            } else { $params.state }
            | upsert is_now_blocked {|state|
                let hour: duration = $params.real_now - ('0am' | into datetime)
                $state.parsed_allowlist
                | any {|it|
                    $hour >= $it.start and $hour <= $it.end
                }
                | not $in
            }
        }
        block: {|params| $params.state.is_now_blocked }
    }
    {
        key: 'total_time'
        priority: 1
        type: 'online'
        update_state: {|params|
            { is_total_exceeded: ($params.counter > $params.config) }
        }
        counter: {|params, states| (
            (not $states.allowed_times.is_now_blocked) and (not $params.state.is_total_exceeded)
        )}
        block: {|params| $params.state.is_total_exceeded }
    }
    {
        key: 'extra_time'
        priority: 2
        type: 'online'
        counter: {|params, states| (
                ($states.allowed_times.is_now_blocked or $states.total_time.is_total_exceeded) 
                and 
                not ($params.counter > $params.config)
        )}
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
    mkdir $data_dir
    
    # Create default data values.
    const SELF_PATH = path self
    let state_summary = (open $SELF_PATH | hash md5) + (open $config_file | hash md5)
    let data_defaults = {
        counters: (
            $checks
            | compact counter
            | each {|check| {$check.key: 0min}} 
            | into record
        )
        last_reset: ($config.day_start | into datetime)
        offline_time: 0min
        state_summary: $state_summary
    }
    
    # Initialize the data file.
    let data_file: path = ($data_dir | path join 'data.nuon')
    if ($data_file | path exists) {
        open $data_file
        | if ($in.state_summary != $state_summary) {
            print "INFO: Current usage data has been reset, because of either an upgrade or a change in the configuration."
            rm $data_file
            $data_defaults | save $data_file
        }
    } else {
        $data_defaults | save $data_file
    }
    
    mut data = open $data_file
    mut online = false
    mut real_now = (0 | into datetime)
    mut now_minus_uptime: datetime = (0 | into datetime)
    mut states = {};
    
    loop {
        let a_new_minute = ((sys host).uptime mod 1min) < $ITERATION_INTERVAL
        
        if $a_new_minute { $data | save -f $data_file }
        alias run-checks = run-checks $real_now $config $data.counters $states
        if $online == false {
            if $a_new_minute {
                let now = (try {
                    http head https://google.com
                    | transpose -rd
                    | get date
                    | into datetime
                })
                if $now != null {
                    $now_minus_uptime = $now - (sys host).uptime
                    $online = true
                }
            }
            if ($data.offline_time > $config.offline_time) { block }
            $data.offline_time = $data.offline_time + $ITERATION_INTERVAL
            let results = run-checks ($checks | where type == offline)
            $data.counters = $results.counters
            $states = $results.states
        } else if $online == true {
            let results = run-checks ($checks | where type == online)
            $data.counters = $results.counters
            $states = $results.states
        }
        sleep $ITERATION_INTERVAL
    }
    ignore
}

# Run the given checks, according to the flow of operation defined in the docs
# Output: new counters and states.
def run-checks [real_now: datetime, config: record, counters: record, states: record, checks: table] {
    
    let states = (
        $states 
        | merge (
            $checks
            | where {$in has update_state}
            | each {|check|
                let check_params = {
                    real_now: $real_now
                    config: ($config | get $check.id)
                    counter: ($counters | get $check.id)
                    state: ($states | get $check.id)
                }
                
                { $check.id: (do $check.update_state $check_params) }
            }
            | into record
    ))
    
    let counters = (
        $counters 
        | merge (
            $checks
            | where {$in has counter}
            | each {|check|
                let check_params = {
                    real_now: $real_now
                    config: ($config | get $check.id)
                    counter: ($counters | get $check.id)
                    state: ($states | get $check.id)
                }
                let new_counter = (
                    $counters 
                    | get $check.id
                    | if (do $check.counter $check_params $states) {
                         $in + $ITERATION_INTERVAL
                    } else {}
                )
                { $check.id: $new_counter }
            }
            | into record
    ))
    
    $checks
    | group-by priority --to-table
    | sort-by priority --reverse
    | get items
    | reduce --fold null {|group, acc|
        if $acc != null {
            $acc
        } else {
            $group
            | each {|check|
                let check_params = {
                    real_now: $real_now
                    config: ($config | get $check.id)
                    counter: ($counters | get $check.id)
                    state: ($states | get $check.id)
                }
                do $check.block $check_params $states
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
# TODO checks are only the ones named in the config file and no more, verification.
# TODO check whether running with admin privileges (is-admin)
 
# # Testing
#
# ### Inputs: 
# - run-period: run every simulated period
# - duration: run for simulated duration
# - start: run starting from simulated start
# - different checks record
# - different config file
# - use-attempt: simulated usage attempt hour ranges, in the allowlist format
# 
# ### Output:
# table of ran-hour, block decisions of all checks
# 
# ### Assertions:
# table of hour, expected block decisions of all checks

