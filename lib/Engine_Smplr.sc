// smplr: transient analysis of the take.
//
// analyse(id, path, frames, threshold, out) waits until `path` holds at
// least `frames` frames (softcut writes the take in the background), then
// runs Onsets over the mix of its channels in a separate scsynth process,
// non-realtime and niced, so the live audio isn't disturbed. The onset times
// (s from the start of the file) go to `out`, one per line, and matron gets
// /smplr/onsets id out (out is "" if the analysis failed).

Engine_Smplr : CroneEngine {
	classvar fftSize = 512;   // ~10.7 ms at 48 kHz; Onsets reports per hop (fftSize / 2)
	classvar preroll = 0.005; // s; Onsets reports up to one hop after the attack
	classvar waitMax = 20;    // s to wait for the file

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		this.addCommand(\analyse, "isifs", { arg msg;
			this.analyse(msg[1], msg[2].asString, msg[3], msg[4], msg[5].asString);
		});
	}

	analyse { arg id, path, frames, threshold, out;
		Routine {
			var info = this.waitForFile(path, frames);
			if(info.isNil) {
				this.reply(id, "");
			} {
				this.runOnsets(id, path, info, threshold, out);
			};
		}.play(SystemClock);
	}

	// [numFrames, sampleRate, numChannels] once the file is complete, nil
	// if it isn't within waitMax
	waitForFile { arg path, frames;
		var waited = 0;
		while { waited < waitMax } {
			var sf = SoundFile.openRead(path);
			if(sf.notNil) {
				var info = [sf.numFrames, sf.sampleRate, sf.numChannels];
				sf.close;
				if(info[0] >= frames and: { info[0] > 0 }) { ^info };
			};
			0.1.wait;
			waited = waited + 0.1;
		};
		^nil
	}

	// Onsets triggers are recorded at control rate into a buffer (one frame
	// per block), written at the end and read back here: the rising edges
	// are the onsets
	runOnsets { arg id, path, info, threshold, out;
		var frames = info[0], sr = info[1], nch = info[2];
		var dur = frames / sr, block = 64;
		var dir = "/tmp/smplr-" ++ id ++ "/";
		var osc = dir ++ "score.osc", trig = dir ++ "onsets.wav";
		var def = SynthDef(\smplr_onsets, { arg buf = 0, rec = 1, thresh = 0.5;
			var sig = PlayBuf.ar(nch, buf, BufRateScale.kr(buf));
			if(nch > 1) { sig = sig.sum / nch };
			RecordBuf.kr(Onsets.kr(FFT(LocalBuf(fftSize), sig), thresh, \rcomplex), rec,
				loop: 0, doneAction: 2);
		});
		File.mkdir(dir);
		Score([
			[0.0, [\d_recv, def.asBytes]],
			[0.0, [\b_allocRead, 0, path]],
			[0.0, [\b_alloc, 1, (frames / block).ceil.asInteger + 1, 1]],
			[0.0, [\s_new, \smplr_onsets, 1000, 0, 0, \thresh, threshold]],
			[dur, [\b_write, 1, trig, "wav", "float"]],
			[dur + 0.01, [\c_set, 0, 0]]
		]).writeOSCFile(osc);
		"nice -n 10 scsynth -o 1 -N % _ % % WAV int16 > /dev/null 2>&1"
		.format(osc.shellQuote, (dir ++ "nrt.wav").shellQuote, sr).unixCmd({ arg code;
			var sf = SoundFile.openRead(trig);
			if(code != 0 or: { sf.isNil }) {
				this.reply(id, "");
			} {
				var data = FloatArray.newClear(sf.numFrames), last = 0;
				sf.readData(data);
				sf.close;
				File.use(out, "w", { arg f;
					data.do { arg v, i;
						if(v > 0 and: { last <= 0 }) {
							f.write(max(0, i * block / sr - preroll).asString ++ "\n");
						};
						last = v;
					};
				});
				this.reply(id, out);
			};
			("rm -rf " ++ dir.shellQuote).unixCmd(postOutput: false);
		}, false);
	}

	reply { arg id, out;
		NetAddr("127.0.0.1", 10111).sendMsg("/smplr/onsets", id, out);
	}

	free {}
}
