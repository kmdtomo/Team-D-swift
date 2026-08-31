#!/usr/bin/env python3
"""Create the exact-size printable T11-01 50mm marker PDF."""
from __future__ import annotations

from pathlib import Path
from reportlab.lib.colors import black, white
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas

MM = 72.0 / 25.4


def create(output: Path):
    output.parent.mkdir(parents=True, exist_ok=True)
    page_width, page_height = A4
    outer = 50.0 * MM
    frame = 5.0 * MM
    x = (page_width - outer) / 2.0
    y = (page_height - outer) / 2.0
    pdf = canvas.Canvas(str(output), pagesize=A4, pageCompression=1, invariant=1)
    pdf.setTitle("Team-D T11-01 50mm Measurement Marker")
    pdf.setAuthor("Team-D Swift")
    pdf.setSubject("Print at 100 percent; verify outer square with a ruler")
    pdf.setFillColor(black)
    pdf.rect(x, y, outer, outer, fill=1, stroke=0)
    pdf.setFillColor(white)
    pdf.rect(x + frame, y + frame, outer - 2 * frame, outer - 2 * frame, fill=1, stroke=0)
    pdf.setFillColor(black)
    pdf.setFont("Helvetica", 9)
    pdf.drawCentredString(page_width / 2.0, y - 12 * MM, "Team-D measurement marker - print at 100% / Actual Size")
    pdf.drawCentredString(page_width / 2.0, y - 16 * MM, "Verify the outer black square is 50.0 mm with a ruler before use.")
    pdf.showPage()
    pdf.save()


if __name__ == "__main__":
    create(Path(__file__).resolve().parents[2] / "output/pdf/t11-01-50mm-marker.pdf")
