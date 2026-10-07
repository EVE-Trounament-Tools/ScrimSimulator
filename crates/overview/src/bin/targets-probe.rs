//! Dev CLI: find the locked-target rings in still frames of a scene (`Scene::targets`) and print
//! what each reads (HP, and the label via Tesseract), for checking `overview::targets` against a
//! recording. Each block is calibrated on the first frame given that has a ring in it.

use anyhow::{Context, Result};
use clap::Parser;
use overview::panel::{crop_scaled, Scene};
use overview::targets::{label_image, ocr_label, read_rings, BlockGeometry};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "targets-probe", about = "Read locked-target HP rings from still frames")]
struct Cli {
    #[arg(long)]
    scene: PathBuf,
    /// Tesseract executable, for the labels.
    #[arg(long, env = "SCRIM_TESSERACT", default_value = "tesseract")]
    tesseract: PathBuf,
    /// Save each label image given to Tesseract here, as `<frame>-<block>-<ring>.png`.
    #[arg(long)]
    dump: Option<PathBuf>,
    /// Frames (PNG), in order.
    frames: Vec<PathBuf>,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let scene = Scene::load(&cli.scene).with_context(|| format!("loading {}", cli.scene.display()))?;
    let mut geoms: Vec<Option<BlockGeometry>> = vec![None; scene.targets.len()];
    for path in &cli.frames {
        let frame = image::open(path).with_context(|| format!("opening {}", path.display()))?.to_rgb8();
        println!("== {}", path.display());
        for (b, rect) in scene.targets.iter().enumerate() {
            let block = crop_scaled(&frame, *rect, 1.0);
            if geoms[b].is_none() {
                geoms[b] = BlockGeometry::calibrate(&block);
            }
            let Some(geom) = &geoms[b] else {
                println!("  block {b}: no rings");
                continue;
            };
            println!("  block {b}: {geom:?}");
            let rings = read_rings(&block, geom);
            let centers: Vec<_> = rings.iter().map(|r| r.center).collect();
            for (i, r) in rings.iter().enumerate() {
                let label = match label_image(&block, &centers, i, geom.scale) {
                    Some(img) => {
                        if let Some(dir) = &cli.dump {
                            let stem = path.file_stem().unwrap_or_default().to_string_lossy();
                            img.save(dir.join(format!("{stem}-{b}-{i}.png")))?;
                        }
                        format!("{:?}", ocr_label(&img, &cli.tesseract)?)
                    }
                    None => "no label".into(),
                };
                println!(
                    "    ({:.0},{:.0}) shield {:.2} armor {:.2} hull {:.2}  {label}",
                    r.center.0, r.center.1, r.hp.shield, r.hp.armor, r.hp.hull
                );
            }
        }
    }
    Ok(())
}
