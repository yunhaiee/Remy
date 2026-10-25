package com.yunha.remy.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunha.remy.RemyModel
import com.yunha.remy.core.CookingSession
import com.yunha.remy.core.EvidenceOrigin
import com.yunha.remy.core.PantryStatus
import com.yunha.remy.core.RecipeStep
import kotlinx.coroutines.launch

/** The landscape "Your session" sheet (ContentView.swift: chef + flowCard): dish composer, ingredient checklist, step card. */
@Composable
fun SessionContent(state: RemyState, model: RemyModel) {
    @Suppress("UNUSED_VARIABLE") val version = state.sessionVersion
    val session = model.session
    val scope = rememberCoroutineScope()
    LazyColumn(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                AppText(state.line, appText(26.sp, color = AppTheme.text, tracking = (-0.4).sp))
                if (state.handsFree && state.isLoaded && state.lastHeard.isNotEmpty()) AppText("“${state.lastHeard}”", appText(13.sp, color = AppTheme.secondary), maxLines = 1)
                AppText(state.status, appText(13.sp, color = AppTheme.secondary))
            }
        }
        when (session.phase) {
            CookingSession.Phase.NEEDS_DISH -> item {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).background(AppTheme.surfaceHigh, RoundedCornerShape(50)).padding(start = 18.dp, end = 6.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) {
                            if (state.dishRequest.isEmpty()) AppText("Say it, or type a dish", appText(17.sp, color = AppTheme.secondary))
                            BasicTextField(state.dishRequest, { state.dishRequest = it }, textStyle = appText(17.sp), singleLine = true,
                                cursorBrush = SolidColor(AppTheme.accent), modifier = Modifier.fillMaxWidth(),
                                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                                keyboardActions = KeyboardActions(onSend = { scope.launch { state.sessionOpen = false; model.planDish() } }))
                        }
                        val ready = state.isLoaded && !state.isBusy && state.dishRequest.isNotBlank()
                        Box(Modifier.size(36.dp).alpha(if (ready) 1f else 0.4f).background(AppTheme.gradient, CircleShape)
                            .clickable(remember { MutableInteractionSource() }, null, enabled = ready) { state.sessionOpen = false; scope.launch { model.planDish() } },
                            contentAlignment = Alignment.Center) { AppText("↑", appText(17.sp, FontWeight.Medium, Color.White)) }
                    }
                    if (state.planIngredients.isNotEmpty()) {
                        Eyebrow("Writing the plan · ${state.planIngredients.size} ingredients · ${state.planSteps.size} steps so far")
                        AppText(state.planIngredients.joinToString(" · "), appText(15.sp))
                    }
                }
            }
            CookingSession.Phase.INGREDIENTS -> {
                val plan = session.plan
                val ready = plan?.ingredients?.count { session.pantry[it.id]?.status == PantryStatus.SEEN } ?: 0
                item(key = "ready$ready") {
                    Row(Modifier.fillMaxWidth()) {
                        Eyebrow(plan?.dish ?: "", AppTheme.secondary); Spacer(Modifier.weight(1f)); Eyebrow("$ready of ${plan?.ingredients?.size ?: 0} ready", AppTheme.secondary)
                    }
                }
                item { AppText("Show me your ingredients", appText(26.sp, tracking = (-0.4).sp)) }
                plan?.ingredients?.forEach { ingredient ->
                    val pantry = session.pantry[ingredient.id]
                    item(key = ingredient.id) {
                        val (text, color) = when (pantry?.status) {
                            PantryStatus.SEEN -> "Have it" to AppTheme.accent
                            PantryStatus.MISSING -> "Missing" to AppTheme.warning
                            PantryStatus.UNSURE -> "Check?" to AppTheme.accentLight
                            null -> "—" to AppTheme.secondary
                        }
                        Row(Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, null) { model.cyclePantry(ingredient.id) }.padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            AppText(ingredient.name, appText(17.sp))
                            AppText(ingredient.amount, appText(12.sp, color = AppTheme.secondary), Modifier.weight(1f))
                            AppText(text + if (pantry?.origin == EvidenceOrigin.USER) " · you" else "", appText(13.sp, FontWeight.Medium, color))
                        }
                    }
                }
                item { AppText("Tap an item to correct it. Your word beats the camera.", appText(12.sp, color = AppTheme.secondary)) }
                item { OutlineButton("Start cooking") { state.sessionOpen = false; model.beginCooking() } }
            }
            CookingSession.Phase.COOKING -> {
                val plan = session.plan
                val total = maxOf(plan?.steps?.size ?: 1, 1)
                item {
                    Row(Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, null) { state.stepsOpen = !state.stepsOpen },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Eyebrow("Step ${session.currentStep + 1} of $total", AppTheme.secondary)
                        Box(Modifier.weight(1f).height(2.dp).background(AppTheme.outline, RoundedCornerShape(50))) {
                            Box(Modifier.fillMaxWidth((session.currentStep + 1f) / total).height(2.dp).background(AppTheme.gradient, RoundedCornerShape(50)))
                        }
                    }
                }
                if (state.stepsOpen) plan?.steps?.forEachIndexed { index, step ->
                    item(key = "s$index") {
                        Row(Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, null) { model.selectStep(index); state.stepsOpen = false },
                            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            AppText(String.format("%02d", index + 1), appText(14.sp, color = AppTheme.secondary))
                            AppText(if (step.kind == RecipeStep.Kind.ASK) "Ask · ${step.title}" else step.title, appText(14.sp), Modifier.weight(1f))
                            AppText(if (session.currentStep == index) "now" else if (session.done.contains(step.id)) "done" else "",
                                appText(12.sp, color = AppTheme.accent))
                        }
                    }
                }
                session.step?.let { step ->
                    item { AppText(step.title, appText(30.sp, tracking = (-0.6).sp)) }
                    item { AppText(if (step.kind == RecipeStep.Kind.ASK) step.question else step.instruction, appText(16.sp, color = AppTheme.secondary)) }
                    if (step.warning.isNotEmpty()) item {
                        Column(Modifier.fillMaxWidth().background(AppTheme.surfaceHigh, RoundedCornerShape(16.dp)).padding(horizontal = 16.dp, vertical = 14.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Eyebrow("Heads up", AppTheme.warning); AppText(step.warning, appText(15.sp))
                        }
                    }
                    if (step.tool.isNotEmpty()) item { AppText("Tool · ${step.tool}", appText(13.sp, color = AppTheme.secondary)) }
                    if (session.unmetNeeds.isNotEmpty()) item { AppText("Not done yet: ${session.unmetNeeds.joinToString { it.title }}", appText(13.sp, color = AppTheme.warning)) }
                    if (step.kind == RecipeStep.Kind.ASK) item { AskAnswer(model) }
                    if (step.isGuarded) item {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            AppText(if (session.salted) "${step.guardItem.replaceFirstChar { it.uppercase() }} remembered · " +
                                (if (session.saltOrigin == EvidenceOrigin.CAMERA) "Gemma observed" else "you confirmed")
                                else "${step.guardItem.replaceFirstChar { it.uppercase() }} not added yet", appText(12.sp, FontWeight.Medium, if (session.salted) AppTheme.accent else AppTheme.text))
                            if (!session.salted) OutlineButton("I added it") { model.confirmSalt() }
                        }
                    }
                    if (step.kind == RecipeStep.Kind.DO) item {
                        val finished = session.isLastStep && session.done.contains(step.id)
                        OutlineButton(if (finished) "Dish finished" else if (session.suggestedCompletion) "Confirm step complete" else if (session.isLastStep) "Finish" else "Next step",
                            enabled = !finished) { model.nextStep() }
                    }
                }
                if (session.preferences.isNotEmpty()) item {
                    AppText("You said · " + session.preferences.toSortedMap().map { "${it.key}: ${it.value}" }.joinToString(" · "), appText(12.sp, color = AppTheme.secondary))
                }
            }
        }
        item { Spacer(Modifier.height(12.dp)) }
    }
}

@Composable
private fun AskAnswer(model: RemyModel) {
    var typed by remember { mutableStateOf("") }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.weight(1f).border(1.dp, AppTheme.outlineStrong, RoundedCornerShape(10.dp)).padding(10.dp)) {
            if (typed.isEmpty()) AppText("or type it", appText(15.sp, color = AppTheme.secondary))
            BasicTextField(typed, { typed = it }, textStyle = appText(15.sp), singleLine = true, cursorBrush = SolidColor(AppTheme.accent),
                modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { model.answerTyped(typed); typed = "" }))
        }
        OutlineButton("Save", enabled = typed.isNotBlank()) { model.answerTyped(typed); typed = "" }
    }
}

/** FrostedActionStyle: text in a 1 dp outline capsule, 44 dp tall. */
@Composable
fun OutlineButton(title: String, enabled: Boolean = true, onTap: () -> Unit) {
    Box(Modifier.heightIn(min = 44.dp).alpha(if (enabled) 1f else 0.45f).border(1.dp, AppTheme.outlineStrong, RoundedCornerShape(50))
        .clickable(remember { MutableInteractionSource() }, null, enabled = enabled, onClick = onTap).padding(horizontal = 18.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center) {
        AppText(title, appText(15.sp, FontWeight.Medium))
    }
}
