# Oracle tests need a standalone HiGHS binary; point OPTEX_HIGHS_EXE at one or
# rely on the default local build path. Missing binary -> oracle tests excluded.
highs_exe =
  System.get_env("OPTEX_HIGHS_EXE", "C:/Users/eduardosalaz/HiGHS/build/bin/highs.exe")

Application.put_env(:optex, :highs_exe, highs_exe)

exclude = if File.exists?(highs_exe), do: [], else: [oracle: true]

ExUnit.start(exclude: exclude)
