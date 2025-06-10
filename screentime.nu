#!/usr/bin/env nu

# TODO checks are only run if their key in the config file is set (not null).
# Ensure priority ladder is short-circuited to not run the block checks down the line

const VERSION = '0.1.0'

const DATA_DIR = '/var/lib/screentimer'
const CONFIG_FILE = '/etc/screentimer/config.toml'
const RUN_PERIOD = 20sec # The period at which the main loop of the application runs.

# Get program configuration.
let config_file: path = $CONFIG_FILE | path expand
if not ($config_file | path exists) {
    print -e $"Error: No configuration file found at path ($config_file)"
    exit 1
}
let config = open $config_file

# Screen time restriction checks' implementation is defined below.
# 
# All checks must have a configuration value set in the configuration file.
# If a check's corresponding configuration option is not set, it will not be run.
#
# Every check is a record with the following keys:
#   - key (string): 
#       The configuration key (in the configuration file) identifying the check.
# 
#   - priority (int): 
#       Priority of the check relative to other checks (see below).
#       Checks with higher priority overrides the result of the checks with lower priority.
#       The results of checks with the same priority are OR'ed. 
#       This means if any one check results in block decision, the system is blocked.
# 
#   - state_update (optional) (closure):
#       Parameters: check parameters (record)
#       Output: any
#       A closure to run to update the state variable of this check.
#       If it returns nothing (null), state variable will not be updated.
#       Checks can persist data between main loop runs and share data with other checks using their state variable.
#       State data is not persisted between program runs, e.g. it'll reset when system shuts down.
# 
#   - counter (optional) (closure):
#       Parameters: check parameters (record), all state variables (record)
#       Output: bool
#       If given, a time counter will be stored on disk for this check.
#       All counters are reset at $config.day_start, if it wasn't possible (e.g. because 
#       the computer was not turned on) they will be reset at the earliest possible time after that.
# 
#   - block (closure):
#       Parameters: check parameters (record), all state variables (record).
#       Output: bool
#       A closure to run to determine whether to block the system.
#       If the output is nothing (null), the check will have no effect on blocking.
# 
# Flow of operation is as follows:
#   1. Run state_update closures of all checks (who have it set).
#   2. Run counter closures of all checks (who have it set).
#   3. Run block closures of all checks (who have it set).
# 
# Check parameters is a record with the following keys:
#   - config (any): check configuration value as defined in the configuration file.
#   - counter (optional) (duration): check counter, if the counter key is defined for the check.
#   - state (optional) (any): check state variable, if the state_update key is defined for the check.

let checks: table<key: string, priority: int, block: closure, counter: closure, state_update: closure> = [
    {
        key: 'offline_time'
        priority: 4
        state_update: {|params|
            let state = $params.state? | default (
                online: false
                real_now: null
                now_minus_uptime: null
            )
            let uptime = (sys host).uptime
            
            # If we were unable to fetch real clock data,
            if $state.online == false { 
                # and only once a minute, 
                if ($uptime mod 1min) < $RUN_PERIOD {
                    # try to fetch real clock data.
                    let now = (try {
                        http head https://google.com  
                        | transpose -rd
                        | get date
                        | into datetime
                    })
                    if $now != null {
                        $state
                        | update online true
                        | update real_now $now
                        | update now_minus_uptime ($now - $uptime)
                    }
                }
            } else {
                $state
                | update real_now ($state.now_minus_uptime + $uptime)
            }
        }
        counter: {|params| not $params.state.online }
        block: {|params|
            if not $params.state.online {
                $params.counter > $params.config
            }
        }
    }
    {
        key: 'allowed_times'
        priority: 1
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
                
                { 
                    is_time_blocked: {|time: datetime|
                        let hour: duration = $time - ('0am' | into datetime)
                        $parsed_allowlist
                        | any {|it|
                            $hour >= $it.start and $hour <= $it.end
                        }
                        | not $in
                    }
                }
            }
        }
        block: {|params, states|
            if $states.offline_time.online {
                do $params.state.is_time_blocked $states.offline_time.real_now
            }
        }
    }
    {
        key: 'total_time'
        priority: 1
        state_update: {|params|
            if params.state? == null {
                { is_total_exceeded: ($params.counter > $params.config) }
            }
        }
        counter: {|params, states| (
            let is_time_blocked = do $states.allowed_times.is_time_blocked $states.offline_time.real_now;
            (not $is_time_blocked) and (not $params.state.is_total_exceeded)
        )}
        block: {|params| $params.state.is_total_exceeded }
    }
    {
        key: 'extra_time'
        priority: 2
        counter: {|params, states|
            let is_time_blocked = do $states.allowed_times.is_time_blocked $states.offline_time.real_now;
            ($is_time_blocked or $states.total_time.is_total_exceeded) and not ($params.counter > $params.config)
        }
        block: {|params| $params.counter > $params.config }
    }
    {
        key: 'after_boot'
        priority: 3
        block: {
            (sys host).uptime <
        }
    }
]

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

def main []: nothing -> nothing {
    mut now_minus_uptime: datetime = (0 | into datetime);    
    mut data = open $data_file
    
    # TODO how do we account for timezone?
    # TODO the issue of needing to reboot times unopened days should be resolved.
    # TODO notify should work, use libnotify (notify-send)
    # TODO handle the case where cross day boundary.
    
    # Updates the counter of the given check.
    # Output: the updated record of counters.
    def update-counter [check: record, counters: record]: nothing -> record {
        if $check.counter? != null {
            if (do $check.counter $counters) { 
                $counters
                | update $check.key { $in + $RUN_PERIOD }
            } else { $counters }
        } else { $counters }
    }
    
    # Determines whether to block or not, given a list of checks.
    def determine_block [checks: table, counters: record]: nothing -> bool {
        $checks
        | group-by priority --to-table 
        | sort-by priority --reverse
        | get items
        | first 
        | reduce --fold false {|check, acc|
            $acc or (do $check.block $counters)
        }
    }
    
    loop {
        let now = (try {
            http head https://google.com  
            | transpose -rd
            | get date
            | into datetime
        })
        
        if $now != null {
            $now_minus_uptime = $now - (sys host).uptime
            break
        } else if $now == null {
            let offline_checks = $checks | filter {$in.online == false}
            $data.counters = (
                $offline_checks
                | reduce --fold $data.counters {|check, counters| 
                    update-counter $check $counters
            })
            if (determine-block $offline_checks $data.counters) {
                block
            }
            
            
            # if $config.offline_time == true {
            #     set-var spent_offline ((get-var spent_offline) + 1min)
            #     if (get-var spent_offline) > $config.offline_time { block }
            # } else if $config.offline_time == false { block }
        }
        save-to-disk
        sleep 1min
    }
    
    # The main loop
    loop {
        let uptime = (sys host).uptime # We freeze the moment in time by fetching the current uptime only once in the main loop.
        
        # first filter the checks by trusted time
        # 
        
        checks | each {|check|
            
        }
        
        # Commit to disk every minute.
        if ($uptime mod 1min) < $RUN_PERIOD {
            $data | save -f $data_file
        }
        sleep $RUN_PERIOD
    }
    
    
    ignore
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
	# print "User is blocked." ; exit # for testing
	if (sys host).uptime >= $config.after_boot_allowed {
		$config.users  | each {
			let user: string = $in
			print $"User \"($user)\" is terminated."
			try { loginctl kill-user $user }
		}
	}
}

# A function to test time allowlist parsing
export def test [] {
	open ./tests.nuon
	| enumerate
	| each {|e|
		let test = $e.item
		let ind = $e.index | $" ($in):" | fill -w 4
		let allowed_hours = $test.allowlist | parse-allowlist
		let result = is-time-allowed $test.hour $allowed_hours
		if $result != $test.expected {
			print $"\n($ind) FAIL: expected ($test.expected) but got ($result)\n"
			print $"\nTested ($test.hour) against ($test.allowlist)"
		} else {
			print $"($ind) PASS: expected ($test.expected) and got ($result)"
		}
	}
	ignore
}

# TODO fix depman
# TODO write tests for every single functionality and edge case out there using depman. If you don't have tests you don't have hope for maintaining.
# TODO use version to determine config file upgrade, using semver. Upgrade is a merge operation.
# TODO implement a version subcommand to print out version.
# TODO checks are only the ones named in the config file and no more, verification.
# TODO check whether running with admin privileges (is-admin)