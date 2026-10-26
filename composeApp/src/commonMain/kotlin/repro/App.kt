package repro

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * One static screen: a title, a counter, two buttons and a short list. Nothing animates and
 * nothing changes unless a button is tapped, so after the first frame Compose has no reason to
 * render or to touch the semantics tree again.
 */
@Composable
fun App() {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                var taps by remember { mutableIntStateOf(0) }
                Text("Accessibility display link repro", style = MaterialTheme.typography.titleLarge)
                Text("Taps: $taps")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { taps++ }) { Text("Tap") }
                    OutlinedButton(onClick = { taps = 0 }) { Text("Reset") }
                }
                HorizontalDivider()
                LazyColumn(modifier = Modifier.fillMaxWidth()) {
                    items((1..30).toList()) { index ->
                        Text("Row $index", modifier = Modifier.padding(vertical = 8.dp))
                    }
                }
            }
        }
    }
}
