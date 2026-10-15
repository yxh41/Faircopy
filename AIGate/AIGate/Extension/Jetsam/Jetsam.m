//
//  Jetsam.c
//  AIGate
//
//  Created by 秋星桥 on 2024/8/16.
//

#import "Jetsam.h"

void JetsamDisableControl(void) {
    memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), 0, NULL, 0);
}
