#Import pytest so we can run the same test with multiple input combinations.
import pytest

#Import the function that converts arousal and valence scores into a tone tag
from ml.tone.backend import map_tag


#Run this test once for every set of arousal, valence, and expected tag values.
@pytest.mark.parametrize("arousal, valence, expected_tag", [
    # High arousal and high valence should produce the excited tag.
        (0.65, 0.46, "excited"),

        # Arousal exactly at 0.64 should not qualify if the cutoff is strict.
        (0.64, 0.46, None),

        # Valence exactly at 0.45 should not qualify if the cutoff is strict.
        (0.70, 0.45, None),

        # Arousal exactly at 0.48 should not qualify for calm if the range is strict.
        (0.48, 0.46, None),

        # Arousal inside the calm range and sufficiently positive valence should produce calm.
        (0.42, 0.46, "calm"),

        # Arousal exactly at the lower calm boundary should not qualify if the cutoff is strict.
        (0.38, 0.46, None),

        # High enough arousal and low valence should produce the upset tag.
        (0.50, 0.39, "upset"),

        # Arousal exactly at 0.47 should not qualify for upset if the cutoff is strict.
        (0.47, 0.30, None),

        # Valence exactly at 0.40 should not qualify for upset if the cutoff is strict.
        (0.60, 0.40, None),
],
)
# Define the test function; pytest supplies each row's values as arguments.
def test_map_tag_cutoffs(arousal, valence, expected_tag):
    # Call map_tag with the scores and verify that its result matches the expected tag.
    assert map_tag(arousal, valence) == expected_tag
