using System.Drawing;

namespace ClaudeQuota;

/// <summary>
/// Diálogo modal minimal para renombrar (proyecto/sesión). Un TextBox precargado + Guardar/Cancelar,
/// espejo del <c>.alert { TextField … }</c> de la vista macOS (PopoverView.swift). Devuelve el texto
/// (posiblemente VACÍO = "restaurar original") o <c>null</c> si se canceló. La semántica de vacío la
/// aplica quien llama vía <see cref="QuotaService.RenameProject"/>/<see cref="QuotaService.RenameSession"/>.
///
/// (Feature A) Cuando se pasa <paramref name="suggestName"/> (solo el rename de SESIÓN lo hace), el
/// diálogo suma un <c>Label</c>/caja de solo-lectura con el <paramref name="summary"/> (contexto de la
/// sesión) y un botón "Sugerir nombre" que corre <c>claude -p</c> (async, sin congelar la UI) y deja el
/// resultado en el TextBox — editable, NO guarda solo. El rename de PROYECTO no pasa esos argumentos, así
/// que ni el contexto ni el botón aparecen.
/// </summary>
internal static class RenameDialog
{
    public static string? Show(IWin32Window owner, string title, string prompt, string current,
        string? summary = null, Func<Task<string?>>? suggestName = null)
    {
        // El contexto + botón son exclusivos de la sesión → los activa la presencia del delegado.
        bool hasContext = suggestName != null;
        const int width = 380;

        using var form = new Form
        {
            Text = title,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterParent,
            MinimizeBox = false,
            MaximizeBox = false,
            ShowInTaskbar = false,
            AutoScaleMode = AutoScaleMode.Dpi,
        };

        int y = 14;
        var lbl = new Label { Left = 14, Top = y, Width = width - 28, Height = 44, Text = prompt };
        form.Controls.Add(lbl);
        y += 48;

        // Contexto (solo sesión): resumen multilínea de solo-lectura para orientar el nombre.
        if (hasContext)
        {
            string ctx = string.IsNullOrWhiteSpace(summary) ? "(sin contexto disponible)" : summary!;
            var ctxBox = new TextBox
            {
                Left = 14, Top = y, Width = width - 28, Height = 72,
                Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical,
                Text = ctx, BorderStyle = BorderStyle.FixedSingle, TabStop = false,
                BackColor = SystemColors.Control,
            };
            form.Controls.Add(ctxBox);
            y += 80;
        }

        var box = new TextBox { Left = 14, Top = y, Width = width - 28, Text = current };
        form.Controls.Add(box);
        y += 36;

        // Botonera: Guardar/Cancelar a la derecha (mismas posiciones que el diálogo base).
        var cancel = new Button { Text = "Cancelar", DialogResult = DialogResult.Cancel, Width = 84, Height = 28, Left = width - 92, Top = y };
        var ok = new Button { Text = "Guardar", DialogResult = DialogResult.OK, Width = 84, Height = 28, Left = cancel.Left - 90, Top = y };
        form.Controls.Add(ok);
        form.Controls.Add(cancel);

        if (hasContext)
        {
            var suggest = new Button { Text = "Sugerir nombre", Width = 118, Height = 28, Left = 14, Top = y };
            suggest.Click += async (_, _) =>
            {
                // Avisa el costo antes de gastar tokens.
                if (MessageBox.Show(form,
                        "“Sugerir nombre” usa la CLI de Claude (claude -p) y CONSUME tokens de tu cuota. ¿Continuar?",
                        "Sugerir nombre", MessageBoxButtons.OKCancel, MessageBoxIcon.Question)
                    != DialogResult.OK) return;

                string prev = suggest.Text;
                suggest.Enabled = false;
                suggest.Text = "Pensando…";
                try
                {
                    string? name = await suggestName!();
                    if (!string.IsNullOrWhiteSpace(name))
                    {
                        box.Text = name!.Trim();
                        box.SelectAll();
                    }
                    else
                    {
                        MessageBox.Show(form,
                            "No se pudo sugerir un nombre (¿está instalado el CLI `claude` en el PATH?).",
                            "Sugerir nombre", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                }
                catch
                {
                    MessageBox.Show(form, "Falló la sugerencia de nombre.",
                        "Sugerir nombre", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
                finally
                {
                    suggest.Text = prev;
                    suggest.Enabled = true;
                    box.Focus();
                }
            };
            form.Controls.Add(suggest);
        }

        y += 40;
        form.ClientSize = new Size(width, y);

        form.AcceptButton = ok;       // Enter → Guardar
        form.CancelButton = cancel;   // Esc → Cancelar
        form.Shown += (_, _) => { box.Focus(); box.SelectAll(); };

        return form.ShowDialog(owner) == DialogResult.OK ? box.Text : null;
    }
}
