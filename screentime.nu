#!/usr/bin/env nu

# v0.1.0 TODOs
#
# TODO implement accurate counter updates (doing http head takes time, that'll create drift over time.)
# TODO comment offline_time out to disable network fetching and trust OS clock
# TODO only increment the counter if the user is logged in
# TODO checks are only run if their key in the config file is set (not null).
# TODO account for timezone
# TODO the issue of needing to reboot times unopened days should be resolved.
# TODO notify should work, use libnotify (notify-send)
# TODO implement day_start
# TODO handle the case where we cross day boundary.
# TODO document dependencies (systemd, notify-send)
# TODO implement specifying different config file
# TODO implement testing as specified in the bottom

const VERSION = '0.1.0'

const DATA_DIR = '/var/lib/screentimer'
const CONFIG_FILE = '/etc/screentimer/config.toml'
const RUN_PERIOD = 30sec # The period at which the main loop of the application runs.

# # Restriction checks implementation
# 
# Implementing screen time constraints for digital devices is a treacherously complex task. There are many edge cases,
# and few solutions which result in low cognitive overhead for the system administrator.
# 
# Here, you can set screen time checks as records with keys defining their state, time counters 
# and block conditions in a declarative manner.
# This design ensures reliability and that checks don't interact with each other in unpredictable ways.
# For example, if the `state_update` closure of checks had access to the state variables of other checks,
# it could result in a situation where the order in which checks' state updates are run would matter.
#
# ## Check structure
#   - key (string): 
#       The configuration key (in the configuration file) identifying the check.
# 
#   - priority (int): 
#       Priority of the check relative to other checks (see below).
#       Checks with higher priority overrides the result of the checks with lower priority.
#       The results of checks with the same priority are OR'ed. 
#       This means if any one check results in block decision, the system is blocked.
#       Checks with the same type will be grouped together before considering priority.
#       This means checks with different types won't affect each other.
# 
#   - type: (string):
#       Type of the check. Possible values: "online", "offline".
#       If set to "online", the check will be enabled only after real clock 
#       data fetched from google.com becomes available.
#       If set to "offline", the check will only be enabled while real clock
#       data is not available.
# 
#   - state_update (optional) (closure):
#       Parameters: check parameters (record)
#       Output: any
#       A closure to run to update the state variable of this check.
#       State variable of the check will be set to the output of this closure.
#       If it returns nothing (null), state variable will not be updated.
# 
#   - counter (optional) (closure):
#       Parameters: check parameters (record), all states (record)
#       Output: bool
#       If given, a time counter will be stored on disk for this check.
#       All counters are reset at $config.day_start, if it wasn't possible (e.g. because 
#       the computer was not turned on) they will be reset at the earliest possible time after that.
# 
#   - block (closure):
#       Parameters: check parameters (record), all states (record).
#       Output: bool
#       A closure to run to determine whether to block the system.
#       If the output is nothing (null), the check will have no effect on blocking.
# 
# ### State variables
# Checks can persist data between runs and share data with other checks using their state variable.
# State data is kept in memory and saved to disk. It'll be reset when screentimer stops running (e.g. when the computer shuts down).
# 
# ### check parameters (record):
#   - real_now (optional) (datetime): real clock fetched from the internet, if it's available.
#   - config (any): this check's configuration value as defined in the configuration file.
#   - counter (optional) (duration): this check's counter, if the counter key is defined for the check.
#   - state (optional) (any): this check's state variable, if the state_update key is defined for the check.
# 
# ### all states (record):
# This is a record containing state variables of all checks, with check ids as keys.
# 
# ### Disabling checks
# All checks must have a configuration value set in the configuration file.
# If a check's corresponding configuration option is not set, it will not be run.
# 
# ## Flow of operation:
# 
# 1, Run all offline checks while also trying to get fetch clock data from google.com.
# 2. Once we fetch the real clock data from google.com, stop running offline checks and start running online checks, indefinitely.
# 
# ### Trusting the system clock instead of online clock data
# 
# If offline_time config option is commented out in the configuration file, screentimer will trust the OS clock instead of 
# trying to fetch the real clock data from google.com.
# In this case, all offline checks will be disabled, and only online checks will be run, regardless of whether there's a network connection or not.
# 
# ### How checks are run (the program loop)
#   1. Run state_update closures of checks (who have it set). Update states accordingly.
#   2. Run counter closures of checks (who have it set). Update counters accordingly.
#   3. Run block closures of checks (who have it set). Determine whether or not to block the user based on the priority of checks.
#   4. If the final result is a block decision, and we are not in `after_boot_allowed` config option, terminate the user's session.
#   5. Wait for a 20 seconds ($RUN_PERIOD).
#   5. Go to 1.

let checks: table<key: string, priority: int, block: closure, counter: closure, state_update: closure> = [
    {
        key: 'allowed_times'
        priority: 1
        type: 'online'
        state_update: {|params|
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
        state_update: {|params|
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
        let uptime = (sys host).uptime
        if ($uptime mod 1min) < $RUN_PERIOD {
            $data | save -f $data_file
        }
        alias run-checks = run-checks $real_now $config $data.counters $states
        if $online == false {
            if ($uptime mod 1min) < $RUN_PERIOD {
                let now = (try {
                    http head https://google.com
                    | transpose -rd
                    | get date
                    | into datetime
                })
                if $now != null {
                    $now_minus_uptime = $now - $uptime
                    $online = true
                }
            }
            if ($data.offline_time > $config.offline_time) { block }
            $data.offline_time = $data.offline_time + $RUN_PERIOD
            let results = run-checks ($checks | where type == offline)
            $data.counters = $results.counters
            $states = $results.states
        } else if $online == true {
            let results = run-checks ($checks | where type == online)
            $data.counters = $results.counters
            $states = $results.states
        }
        sleep $RUN_PERIOD
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
            | filter {$in has state_update}
            | each {|check|
                let check_params = {
                    real_now: $real_now
                    config: ($config | get $check.id)
                    counter: ($counters | get $check.id)
                    state: ($states | get $check.id)
                }
                
                { $check.id: (do $check.state_update $check_params) }
            }
            | into record
    ))
    
    let counters = (
        $counters 
        | merge (
            $checks
            | filter {$in has counter}
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
                         $in + $RUN_PERIOD
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
            | filter {$in != null} 
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

