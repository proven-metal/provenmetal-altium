using System;
using System.Drawing;
using System.Windows.Forms;
using ProvenMetal.Core;

namespace ProvenMetal.UI
{
    // Branded live-progress + results window (mirrors the KiCad plugin v0.1.7 UX):
    // opens immediately, streams progress while sourcing, then fills in the verdict.
    // Black canvas, bone mono type, one signal-red for the fail count.
    public class ResultsForm : Form
    {
        private static readonly Color Canvas = Color.FromArgb(10, 10, 10);
        private static readonly Color PanelBg = Color.FromArgb(20, 20, 20);
        private static readonly Color Bone = Color.FromArgb(244, 246, 248);
        private static readonly Color Steel = Color.FromArgb(154, 167, 176);
        private static readonly Color Red = Color.FromArgb(255, 0, 33);
        private static readonly Color Line = Color.FromArgb(45, 45, 45);

        private readonly Label _status;
        private readonly FlowLayoutPanel _counts;
        private readonly ProgressBar _bar;
        private readonly TextBox _log;
        private readonly Button _open;
        private readonly Button _close;
        private string _reportUrl = "";

        public ResultsForm()
        {
            Text = "ProvenMetal Sourcing";
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(640, 520);
            BackColor = Canvas;
            Font = new Font("Consolas", 9F);
            MinimizeBox = true;
            MaximizeBox = true;

            var word = new Label
            {
                Text = "PROVENMETAL",
                ForeColor = Bone,
                Font = new Font("Consolas", 16F, FontStyle.Bold),
                AutoSize = true,
                Location = new Point(18, 16),
                BackColor = Color.Transparent
            };
            var sub = new Label
            {
                Text = "BOM SOURCING",
                ForeColor = Steel,
                Font = new Font("Consolas", 8F),
                AutoSize = true,
                Location = new Point(20, 46),
                BackColor = Color.Transparent
            };
            var hair = new Panel
            {
                BackColor = Line,
                Location = new Point(18, 74),
                Size = new Size(ClientSize.Width - 36, 1),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right
            };

            _status = new Label
            {
                Text = "Working ...",
                ForeColor = Steel,
                Font = new Font("Consolas", 12F, FontStyle.Bold),
                AutoSize = false,
                Location = new Point(18, 88),
                Size = new Size(ClientSize.Width - 36, 24),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                BackColor = Color.Transparent
            };

            _counts = new FlowLayoutPanel
            {
                Location = new Point(16, 116),
                Size = new Size(ClientSize.Width - 32, 26),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                BackColor = Color.Transparent,
                WrapContents = false,
                AutoSize = false
            };

            _bar = new ProgressBar
            {
                Location = new Point(18, 148),
                Size = new Size(ClientSize.Width - 36, 12),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                Style = ProgressBarStyle.Marquee,
                MarqueeAnimationSpeed = 30
            };

            _log = new TextBox
            {
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Both,
                WordWrap = false,
                BackColor = PanelBg,
                ForeColor = Bone,
                Font = new Font("Consolas", 9F),
                BorderStyle = BorderStyle.FixedSingle,
                Location = new Point(18, 170),
                Size = new Size(ClientSize.Width - 36, ClientSize.Height - 170 - 52),
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right
            };

            _open = new Button
            {
                Text = "Open report",
                Enabled = false,
                Size = new Size(110, 28),
                Location = new Point(ClientSize.Width - 232, ClientSize.Height - 40),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Right,
                FlatStyle = FlatStyle.System
            };
            _open.Click += (s, e) => { if (!string.IsNullOrEmpty(_reportUrl)) Util.OpenUrl(_reportUrl); };

            _close = new Button
            {
                Text = "Close",
                Enabled = false,
                Size = new Size(100, 28),
                Location = new Point(ClientSize.Width - 116, ClientSize.Height - 40),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Right,
                FlatStyle = FlatStyle.System
            };
            _close.Click += (s, e) => Close();

            Controls.Add(word);
            Controls.Add(sub);
            Controls.Add(hair);
            Controls.Add(_status);
            Controls.Add(_counts);
            Controls.Add(_bar);
            Controls.Add(_log);
            Controls.Add(_open);
            Controls.Add(_close);
        }

        public void SetStatus(string text)
        {
            _status.Text = text;
        }

        public void AppendLog(string msg)
        {
            _log.AppendText(msg + "\r\n");
        }

        private void AddChip(string caption, Color color)
        {
            var l = new Label
            {
                Text = caption,
                ForeColor = color,
                Font = new Font("Consolas", 13F, FontStyle.Bold),
                AutoSize = true,
                Margin = new Padding(0, 0, 22, 0),
                BackColor = Color.Transparent
            };
            _counts.Controls.Add(l);
        }

        public void ShowResults(RunResult r)
        {
            _bar.Style = ProgressBarStyle.Continuous;
            _bar.Value = _bar.Maximum;

            _status.Text = string.IsNullOrEmpty(r.Ref) ? "DONE" : "DONE   " + r.Ref;
            _status.ForeColor = Bone;

            _counts.Controls.Clear();
            AddChip("PARTS " + r.Total, Steel);
            AddChip("PASS " + r.Pass, Bone);
            AddChip("REVIEW " + r.Review, Steel);
            AddChip("FAIL " + r.Fail, r.Fail > 0 ? Red : Steel);

            AppendLog("");
            AppendLog(SummaryText(r));

            _reportUrl = r.ReportUrl;
            _open.Enabled = !string.IsNullOrEmpty(_reportUrl);
            _close.Enabled = true;
        }

        public void ShowError(string message)
        {
            _bar.Style = ProgressBarStyle.Continuous;
            _bar.Value = 0;
            _status.Text = "SOMETHING WENT WRONG";
            _status.ForeColor = Red;
            AppendLog("");
            AppendLog("ERROR: " + message);
            _close.Enabled = true;
        }

        private static string SummaryText(RunResult r)
        {
            var sb = new System.Text.StringBuilder();
            sb.AppendLine("Parts: " + r.Total + "   Pass: " + r.Pass +
                          "   Needs review: " + r.Review + "   Fail: " + r.Fail);
            if (r.Status == "no-sourcing")
                sb.AppendLine("Note: sourcing service not configured on the server - BOM stored, not sourced.");
            else if (r.Status == "degraded")
                sb.AppendLine("Note: sourcing was degraded (timed out) - some lines may need a re-check.");
            if (!string.IsNullOrEmpty(r.SourcingError))
                sb.AppendLine("Sourcing note: " + r.SourcingError);
            foreach (var w in r.Warnings)
                sb.AppendLine("Warning: " + w);

            int shown = 0, flagged = 0;
            foreach (var ln in r.Lines)
            {
                if (ln.Verdict == "fail" || ln.Verdict == "review")
                {
                    flagged++;
                    if (shown < 15)
                    {
                        if (shown == 0) { sb.AppendLine(); sb.AppendLine("Needs attention:"); }
                        sb.AppendLine("  [" + (ln.Verdict ?? "").ToUpperInvariant() + "] " +
                                      ln.Reference + "  " + ln.Part + "  " + ln.Reason);
                        shown++;
                    }
                }
            }
            if (flagged > 15) sb.AppendLine("  ... and " + (flagged - 15) + " more");
            if (flagged == 0) sb.AppendLine("All parts are in stock or sourceable within a week.");

            sb.AppendLine();
            sb.AppendLine("Full report: " + r.ReportUrl);
            return sb.ToString();
        }
    }
}
