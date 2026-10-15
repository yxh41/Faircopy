//
//  Jetsam.h
//  AIGate
//
//  Created by 秋星桥 on 2024/8/16.
//

#ifndef Jetsam_h
#define Jetsam_h

#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <sys/types.h>
#import <sys/proc.h>

#define JETSAM_PRIORITY_REVISION                  2

#define JETSAM_PRIORITY_IDLE_HEAD                -2
#define JETSAM_PRIORITY_IDLE                      0
#define JETSAM_PRIORITY_IDLE_DEFERRED             1
#define JETSAM_PRIORITY_AGING_BAND1               JETSAM_PRIORITY_IDLE_DEFERRED
#define JETSAM_PRIORITY_BACKGROUND_OPPORTUNISTIC  2
#define JETSAM_PRIORITY_AGING_BAND2               JETSAM_PRIORITY_BACKGROUND_OPPORTUNISTIC
#define JETSAM_PRIORITY_BACKGROUND                3
#define JETSAM_PRIORITY_ELEVATED_INACTIVE         JETSAM_PRIORITY_BACKGROUND
#define JETSAM_PRIORITY_MAIL                      4
#define JETSAM_PRIORITY_PHONE                     5
#define JETSAM_PRIORITY_UI_SUPPORT                8
#define JETSAM_PRIORITY_FOREGROUND_SUPPORT        9
#define JETSAM_PRIORITY_FOREGROUND               10
#define JETSAM_PRIORITY_AUDIO_AND_ACCESSORY      12
#define JETSAM_PRIORITY_CONDUCTOR                13
#define JETSAM_PRIORITY_HOME                     16
#define JETSAM_PRIORITY_EXECUTIVE                17
#define JETSAM_PRIORITY_IMPORTANT                18
#define JETSAM_PRIORITY_CRITICAL                 19
#define JETSAM_PRIORITY_MAX                      21

#define MEMORYSTATUS_CMD_GET_PRIORITY_LIST            1
#define MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES      2
#define MEMORYSTATUS_CMD_GET_JETSAM_SNAPSHOT          3
#define MEMORYSTATUS_CMD_GET_PRESSURE_STATUS          4
#define MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK   5
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT        6
#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES      7
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES      8
#define MEMORYSTATUS_CMD_PRIVILEGED_LISTENER_ENABLE   9
#define MEMORYSTATUS_CMD_PRIVILEGED_LISTENER_DISABLE  10
#define MEMORYSTATUS_CMD_AGGRESSIVE_JETSAM_LENIENT_MODE_ENABLE  11
#define MEMORYSTATUS_CMD_AGGRESSIVE_JETSAM_LENIENT_MODE_DISABLE 12
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_EXCESS          13
#define MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE         14
#define MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE        15
#define MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED       16
#define MEMORYSTATUS_CMD_GET_PROCESS_IS_MANAGED       17
#define MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE     18
#define MEMORYSTATUS_CMD_GET_PROCESS_IS_FREEZABLE     19
#define MEMORYSTATUS_CMD_GRP_SET_PROPERTIES           100

typedef struct memorystatus_priority_properties {
    int32_t  priority;
    uint64_t user_data;
} memorystatus_priority_properties_t;

int memorystatus_get_level(user_addr_t level);
int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);

int proc_track_dirty(pid_t pid, uint32_t flags);

void JetsamDisableControl(void);

#endif /* Jetsam_h */
