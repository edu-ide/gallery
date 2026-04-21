/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.google.ai.edge.gallery.ui.unifiedchat

data class AgentSkillState(
  val visibleSkillIds: List<String> = emptyList(),
  val activeSkillIds: Set<String> = emptySet(),
) {
  fun withSkill(skillId: String, active: Boolean): AgentSkillState {
    if (!visibleSkillIds.contains(skillId)) {
      return this
    }

    return copy(
      activeSkillIds =
        if (active) {
          activeSkillIds + skillId
        } else {
          activeSkillIds - skillId
        }
    )
  }

  fun toggle(skillId: String): AgentSkillState =
    withSkill(skillId = skillId, active = !activeSkillIds.contains(skillId))
}
